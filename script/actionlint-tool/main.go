package main

import (
	"os"

	"github.com/rhysd/actionlint"

	_ "time/tzdata"
)

func configureJobContext() {
	job := actionlint.BuiltinGlobalVariableTypes["job"].DeepCopy().(*actionlint.ObjectType)
	for _, name := range []string{"workflow_ref", "workflow_sha", "workflow_repository", "workflow_file_path"} {
		job.Props[name] = actionlint.StringType{}
	}
	actionlint.BuiltinGlobalVariableTypes["job"] = job
}

func main() {
	configureJobContext()
	cmd := actionlint.Command{Stdin: os.Stdin, Stdout: os.Stdout, Stderr: os.Stderr}
	os.Exit(cmd.Main(os.Args))
}
