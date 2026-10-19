"""Bind the actual native New Music Video actions to its built pack and saved pin."""
import hashlib
import json
from pathlib import Path
import plistlib
import uuid
import zipfile
from xml.parsers.expat import ExpatError
import zlib


def local(directory, name):
    if not isinstance(name, str) or not name or Path(name).name != name or name.startswith('.'):
        raise ValueError('Invalid native creation evidence path')
    path = Path(directory) / name
    if not path.is_file() or path.is_symlink():
        raise ValueError('Missing native creation evidence')
    return path


def validate(directory, report, scale):
    directory = Path(directory)
    name = 'hostflow-new-project-result.json'
    if report.get('nativeProjectCreation') != name:
        raise ValueError('Music Video did not start at native New')
    record = json.loads(local(directory, name).read_text())
    progress = json.loads(local(directory, record['progress']).read_text())
    if (progress.get('failure') is not None or progress.get('interactions') != record['interactions']
            or progress.get('screenshots') != record['screenshots']):
        raise ValueError('Native creation progress differs from its result')
    actions = record['interactions']
    if not isinstance(actions, list) or not all(isinstance(item, dict) for item in actions):
        raise ValueError('Malformed native creation actions')
    decisions = [item['id'] for item in actions if item.get('kind') == 'pointer'
                 and item.get('id') in {'home.new', 'home.format.musicvideo', 'home.format.create', 'dock.start'}]
    if decisions != ['home.new', 'home.format.musicvideo', 'home.format.create', 'dock.start']:
        raise ValueError('Missing or reordered native Music Video decisions')
    save = [i for i, item in enumerate(actions) if item.get('kind') == 'save-panel']
    start = next(i for i, item in enumerate(actions) if item.get('kind') == 'pointer' and item.get('id') == 'dock.start')
    create = next(i for i, item in enumerate(actions) if item.get('kind') == 'pointer' and item.get('id') == 'home.format.create')
    if (len(save) != 1 or not create < save[0] < start or actions[save[0]].get('filename') != 'Native Music Video.ngv'
            or actions[save[0]].get('nativeDirectoryAndFilenameTyped') is not True
            or actions[save[0]].get('exactURLVerified') is not True):
        raise ValueError('Native Music Video did not use its real Save panel before production')
    observation_indices = [i for i, item in enumerate(actions) if item.get('kind') == 'verified-state' and item.get('label') == 'native New Music Video completed']
    if len(observation_indices) != 1 or observation_indices[0] <= start:
        raise ValueError('Native Music Video completion did not follow its actual Start')
    observations = [item['evidence'] for item in actions if item.get('kind') == 'verified-state'
                    and item.get('label') == 'native New Music Video completed']
    if len(observations) != 1:
        raise ValueError('Missing exact native Music Video creation observation')
    observed = observations[0]
    settings_bytes = local(directory, 'native-new-project-ngv.json').read_bytes()
    catalog_bytes = local(directory, 'native-new-project-catalog.json').read_bytes()
    archive = local(directory, 'native-new-musicvideo-pack.zip')
    settings, catalog = json.loads(settings_bytes), json.loads(catalog_bytes)
    try:
        with zipfile.ZipFile(archive) as pack:
            names = [n for n in pack.namelist() if n.endswith('.ngvpack/Contents/Info.plist') and not n.startswith('__MACOSX/')]
            if len(names) != 1:
                raise ValueError('The actual pack ZIP has no unique bundle metadata')
            info = plistlib.loads(pack.read(names[0]))
    except (zipfile.BadZipFile, plistlib.InvalidFileException, ExpatError, EOFError, RuntimeError, NotImplementedError, zlib.error) as error:
        raise ValueError('Invalid actual pack metadata') from error
    binding = {'id': info['NGVPackID'], 'version': info['CFBundleShortVersionString'], 'projectSchema': info['NGVProjectSchema']}
    uuid.UUID(settings['id'])
    if (observed.get('projectID') != settings['id'] or binding['id'] != 'musicvideo' or observed.get('binding') != binding
            or settings.get('activePlugin') != binding['id'] or settings.get('activePluginVersion') != binding['version']
            or settings.get('activePluginProjectSchema') != binding['projectSchema'] or settings.get('productionContract') is not None
            or observed.get('settingsSHA256') != hashlib.sha256(settings_bytes).hexdigest()
            or observed.get('catalogSHA256') != hashlib.sha256(catalog_bytes).hexdigest()
            or observed.get('zipSHA256') != hashlib.sha256(archive.read_bytes()).hexdigest()
            or len(catalog.get('plugins', [])) != 1):
        raise ValueError('Native saved pin differs from actual pack/catalog bytes')
    started_bytes = local(directory, 'native-new-project-started-ngv.json').read_bytes()
    intake_bytes = local(directory, 'intake-project-ngv.json').read_bytes()
    started, intake_settings = json.loads(started_bytes), json.loads(intake_bytes)
    intake_record = json.loads(local(directory, 'hostflow-track-lyrics-result.json').read_bytes())
    intake_observations = [row.get('evidence', {}) for row in intake_record['interactions']
        if row.get('kind') == 'verified-state' and row.get('label') == 'native Track and optional Lyrics intake']
    if (len(intake_observations) != 1 or intake_observations[0].get('projectKey') != settings['id']
        or intake_observations[0].get('settingsSHA256') != hashlib.sha256(intake_bytes).hexdigest()
        or observed.get('startedSettingsSHA256') != hashlib.sha256(started_bytes).hexdigest()
        or observed.get('activation') != 'already-loaded-same-CI-pack' or observed.get('unexpectedRequests') != []
        or any(value.get('id') != settings['id'] or value.get('activePlugin') != binding['id']
            or value.get('activePluginVersion') != binding['version'] or value.get('activePluginProjectSchema') != binding['projectSchema']
            or value.get('productionContract') is not None for value in (started, intake_settings))):
        raise ValueError('Native New and actual Track intake belong to different projects or pins')
    entry = catalog['plugins'][0]
    if (any(entry.get(k) != v for k, v in binding.items()) or entry.get('sha256') != observed['zipSHA256']
            or entry.get('migratesFrom') != info.get('NGVMigratesFrom', [])
            or entry.get('minAppVersion') != info['NGVMinAppVersion'] or not entry.get('url', '').startswith('https://')
            or type(observed.get('catalogRequests')) is not int or observed['catalogRequests'] < 1
            or type(observed.get('zipRequests')) is not int or observed['zipRequests'] != 1
            or not all(observed.get(k) is True for k in ('freshCatalogGate', 'realInstallerAndSignature', 'pipelineAbsentBeforeStart', 'runtimeFixture'))
            or observed.get('liveCatalog') is not False or observed.get('nextIntake') != 'Track'
            or observed.get('viewport') != {'width': 960, 'height': 640, 'textScale': scale}):
        raise ValueError('Native fresh-catalog installation/start/viewport evidence is incomplete')
    images = record['screenshots']
    if (not isinstance(images, list) or len(images) != len(set(images)) or len(images) < 4
            or not any(n.endswith('-native-musicvideo-format.png') for n in images)
            or not any(n.endswith('-native-musicvideo-before-start.png') for n in images)):
        raise ValueError('Missing native creation images')
    for name in images:
        data = local(directory, name).read_bytes()
        if len(data) <= 1000 or not data.startswith(b'\x89PNG\r\n\x1a\n'):
            raise ValueError('Invalid native creation screenshot')
    return images
