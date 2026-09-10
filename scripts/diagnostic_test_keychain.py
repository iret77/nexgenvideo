import ctypes as C
from contextlib import ExitStack, contextmanager
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import subprocess
import sys
import tempfile
import uuid


SERVICE = "de.h5ventures.nexgenvideo"


def security(*arguments):
    try:
        result = subprocess.run(["/usr/bin/security", *arguments], capture_output=True,
                                text=True, timeout=15)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"security {arguments[0]} timed out") from None
    if result.returncode:
        raise RuntimeError(f"security {arguments[0]} failed ({result.returncode})")
    return result.stdout.strip()


@contextmanager
def isolated_keychain():
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("diagnostic keychain isolation is restricted to macOS Actions")
    original_default = shlex.split(security("default-keychain", "-d", "user"))
    original_search = shlex.split(security("list-keychains", "-d", "user"))
    if len(original_default) != 1 or not original_search:
        raise RuntimeError("cannot preserve the runner keychain configuration")
    with ExitStack() as cleanup:
        folder = cleanup.enter_context(tempfile.TemporaryDirectory(prefix="ngv-diagnostic-keychain-"))
        path = str(Path(folder) / "acceptance.keychain-db")
        password = secrets.token_hex(32)
        security("create-keychain", "-p", password, path)
        cleanup.callback(security, "delete-keychain", path)
        cleanup.callback(security, "list-keychains", "-d", "user", "-s", *original_search)
        cleanup.callback(security, "default-keychain", "-d", "user", "-s", *original_default)
        security("set-keychain-settings", "-lut", "1800", path)
        security("unlock-keychain", "-p", password, path)
        security("list-keychains", "-d", "user", "-s", path)
        security("default-keychain", "-d", "user", "-s", path)
        yield DiagnosticKeychain(path, password)


class DiagnosticKeychain:
    def __init__(self, path, password):
        self.path = path
        self.password = password

    def read_retained_key(self, account):
        if not account.startswith("hang-diagnostic-"):
            raise ValueError("expected a synthetic diagnostic account")
        uuid.UUID(account.removeprefix("hang-diagnostic-"))
        security("lock-keychain", self.path)
        security("unlock-keychain", "-p", self.password, self.path)
        self._grant_reader(account)
        return security("find-generic-password", "-s", SERVICE, "-a", account, "-w", self.path)

    def _grant_reader(self, account):
        cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        sec = C.CDLL("/System/Library/Frameworks/Security.framework/Security")
        ref, out, integer = C.c_void_p, C.POINTER(C.c_void_p), C.c_uint32
        prompt_selector = C.c_uint16

        def bind(library, name, result, *arguments):
            function = getattr(library, name)
            function.restype, function.argtypes = result, arguments
            return function

        release = bind(cf, "CFRelease", None, ref)
        count = bind(cf, "CFArrayGetCount", C.c_long, ref)
        at = bind(cf, "CFArrayGetValueAtIndex", ref, ref, C.c_long)
        mutable_copy = bind(cf, "CFArrayCreateMutableCopy", ref, ref, C.c_long, ref)
        append = bind(cf, "CFArrayAppendValue", None, ref, ref)
        string_create = bind(cf, "CFStringCreateWithCString", ref, ref, C.c_char_p, integer)
        string_length = bind(cf, "CFStringGetLength", C.c_long, ref)
        string_read = bind(cf, "CFStringGetCString", C.c_bool, ref, C.c_void_p, C.c_long, integer)
        open_keychain = bind(sec, "SecKeychainOpen", C.c_int32, C.c_char_p, out)
        find = bind(sec, "SecKeychainFindGenericPassword", C.c_int32,
                    ref, integer, C.c_char_p, integer, C.c_char_p, ref, ref, out)
        copy_access = bind(sec, "SecKeychainItemCopyAccess", C.c_int32, ref, out)
        item_keychain = bind(sec, "SecKeychainItemCopyKeychain", C.c_int32, ref, out)
        keychain_path = bind(sec, "SecKeychainGetPath", C.c_int32, ref, C.POINTER(integer), C.c_void_p)
        matching = bind(sec, "SecAccessCopyMatchingACLList", ref, ref, ref)
        contents = bind(sec, "SecACLCopyContents", C.c_int32, ref, out, out, C.POINTER(prompt_selector))
        set_contents = bind(sec, "SecACLSetContents", C.c_int32, ref, ref, ref, prompt_selector)
        trusted_app = bind(sec, "SecTrustedApplicationCreateFromPath", C.c_int32, C.c_char_p, out)
        # The same SPI used by security(1) changes only this disposable item's access, never its bytes.
        set_access = bind(sec, "SecKeychainItemSetAccessWithPassword", C.c_int32,
                          ref, ref, integer, C.c_char_p)

        def check(status):
            if status:
                raise RuntimeError(f"synthetic keychain access failed ({status})")

        with ExitStack() as cleanup:
            def own(value):
                if value:
                    cleanup.callback(release, value)
                return value

            def required(value):
                if not value:
                    raise RuntimeError("missing synthetic credential access object")
                return value

            keychain, item, access, reader = ref(), ref(), ref(), ref()
            check(open_keychain(self.path.encode(), C.byref(keychain)))
            required(own(keychain))
            service, account_bytes = SERVICE.encode(), account.encode()
            check(find(keychain, len(service), service, len(account_bytes), account_bytes,
                       None, None, C.byref(item)))
            required(own(item))
            actual_keychain = ref()
            check(item_keychain(item, C.byref(actual_keychain)))
            required(own(actual_keychain))
            path_buffer = C.create_string_buffer(4096)
            path_size = integer(len(path_buffer))
            check(keychain_path(actual_keychain, C.byref(path_size), path_buffer))
            if Path(os.fsdecode(path_buffer.value)).resolve() != Path(self.path).resolve():
                raise RuntimeError("synthetic credential is outside the disposable keychain")
            check(copy_access(item, C.byref(access)))
            required(own(access))
            check(trusted_app(b"/usr/bin/security", C.byref(reader)))
            required(own(reader))
            for authorization in ("kSecACLAuthorizationDecrypt", "kSecACLAuthorizationPartitionID"):
                acls = own(matching(access, ref.in_dll(sec, authorization)))
                if not acls or not count(acls):
                    if authorization == "kSecACLAuthorizationPartitionID":
                        continue
                    raise RuntimeError(f"missing synthetic credential ACL: {authorization}")
                for index in range(count(acls)):
                    acl = required(at(acls, index))
                    applications, description, prompt = ref(), ref(), prompt_selector()
                    check(contents(acl, C.byref(applications), C.byref(description), C.byref(prompt)))
                    own(applications)
                    own(description)
                    if authorization == "kSecACLAuthorizationDecrypt":
                        if applications:
                            applications = required(own(mutable_copy(None, 0, applications)))
                            append(applications, reader)
                    else:
                        required(description)
                        buffer = C.create_string_buffer(4 * (string_length(description) + 1))
                        if not string_read(description, buffer, len(buffer), 0x08000100):
                            raise RuntimeError("unreadable synthetic credential partitions")
                        partitions = plistlib.loads(bytes.fromhex(buffer.value.decode()))
                        values = partitions["Partitions"]
                        if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
                            raise RuntimeError("invalid synthetic credential partitions")
                        if "apple-tool:" not in values:
                            values.append("apple-tool:")
                        encoded = plistlib.dumps(partitions, fmt=plistlib.FMT_XML).hex().encode()
                        description = required(own(string_create(None, encoded, 0x08000100)))
                    check(set_contents(acl, applications, description, prompt))
            password = self.password.encode()
            check(set_access(item, access, len(password), password))


def verify_reader(app):
    with isolated_keychain() as keychain:
        account = f"hang-diagnostic-{uuid.uuid4()}"
        value = secrets.token_hex(32)
        security("add-generic-password", "-s", SERVICE, "-a", account, "-w", value,
                 "-T", str(app / "Contents/MacOS/NexGenVideo"), keychain.path)
        if keychain.read_retained_key(account) != value:
            raise RuntimeError("synthetic keychain reader changed credential bytes")
    print("Disposable keychain reader verified.")


if __name__ == "__main__":
    verify_reader(Path(sys.argv[1]))
