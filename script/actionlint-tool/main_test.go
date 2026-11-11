package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/rhysd/actionlint"
)

func lint(text string) (int, string) {
	configureJobContext()
	var output bytes.Buffer
	cmd := actionlint.Command{Stdin: strings.NewReader(text), Stdout: &output, Stderr: &output}
	return cmd.Main([]string{"actionlint", "-shellcheck=", "-pyflakes=", "-"}), output.String()
}

func TestWorkflowIdentityFieldsPreserveStrictJobSchema(t *testing.T) {
	workflow := `name: Job identity
on: workflow_dispatch
jobs:
  verify:
    runs-on: ubuntu-24.04
    steps:
      - run: echo done
        env:
          SHA: ${{ job.workflow_sha }}
          REF: ${{ job.workflow_ref }}
          REPOSITORY: ${{ job.workflow_repository }}
          PATH: ${{ job.workflow_file_path }}
`
	if code, output := lint(workflow); code != 0 {
		t.Fatalf("documented workflow identities rejected: %s", output)
	}
	if code, _ := lint(strings.ReplaceAll(workflow, "job.workflow_sha", "job.workflow_sha_typo")); code == 0 {
		t.Fatal("unknown job property was accepted")
	}
}

func TestRunnerContextStillFailsBeforeRunnerAllocation(t *testing.T) {
	workflow := `name: Invalid job environment
on: workflow_dispatch
jobs:
  verify:
    runs-on: ubuntu-24.04
    env:
      ROOT: ${{ runner.temp }}
    steps:
      - run: echo done
`
	if code, output := lint(workflow); code == 0 || !strings.Contains(output, "runner") {
		t.Fatalf("invalid runner context was accepted: %s", output)
	}
}
