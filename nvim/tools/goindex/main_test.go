package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

const fixture = `package sample

import "errors"

const (
	SchemaBootstrap = "bootstrap"
	SchemaTaskState = "state"
)

var (
	ErrNotFound = errors.New("missing")
	ErrInvalidState = errors.New("invalid")
)

type State struct {
	Schema string
	TaskID string
	Artifacts map[string]string
}

type Store interface {
	Save(state State) error
}

type Memory struct { tasks map[string]State }

func (m *Memory) Save(state State) error {
	if state.Schema != SchemaTaskState || state.TaskID == "" {
		return ErrInvalidState
	}
	m.tasks[state.TaskID] = state
	return nil
}
`

func findSymbol(index *FileIndex, kind, name string) *Symbol {
	for i := range index.Symbols {
		if index.Symbols[i].Kind == kind && index.Symbols[i].Name == name {
			return &index.Symbols[i]
		}
	}
	return nil
}

func TestExactSymbolsAndMembers(t *testing.T) {
	parsed, err := parseFile("sample.go", []byte(fixture), false)
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range []struct{ kind, name string }{
		{"const", "SchemaBootstrap"},
		{"const", "SchemaTaskState"},
		{"var", "ErrNotFound"},
		{"var", "ErrInvalidState"},
		{"struct", "State"},
		{"field", "Schema"},
		{"field", "TaskID"},
		{"interface", "Store"},
		{"interface_method", "Save"},
		{"method", "Save"},
	} {
		if findSymbol(parsed.index, item.kind, item.name) == nil {
			t.Fatalf("missing %s %s", item.kind, item.name)
		}
	}
	schema := findSymbol(parsed.index, "const", "SchemaTaskState")
	if got := parsed.index.Source[schema.StartOffset:schema.EndOffset]; got != `SchemaTaskState = "state"` {
		t.Fatalf("SchemaTaskState source = %q", got)
	}
	invalid := findSymbol(parsed.index, "var", "ErrInvalidState")
	if got := parsed.index.Source[invalid.StartOffset:invalid.EndOffset]; got != `ErrInvalidState = errors.New("invalid")` {
		t.Fatalf("ErrInvalidState source = %q", got)
	}
}

func TestOccurrencesPreserveMaterialSymbols(t *testing.T) {
	parsed, err := parseFile("sample.go", []byte(fixture), false)
	if err != nil {
		t.Fatal(err)
	}
	save := findSymbol(parsed.index, "method", "Save")
	if save == nil {
		t.Fatal("Save missing")
	}
	want := map[string]bool{
		"Schema": false, "SchemaTaskState": false, "TaskID": false,
		"ErrInvalidState": false, "tasks": false,
	}
	for _, occurrence := range save.Occurrences {
		if _, ok := want[occurrence.Name]; ok {
			want[occurrence.Name] = true
		}
	}
	for name, found := range want {
		if !found {
			t.Fatalf("missing occurrence %s", name)
		}
	}
}

func runTestGit(t *testing.T, root string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v: %s", args, err, output)
	}
}

func TestSnapshotUsesChangedDeclaration(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "sample.go")
	if err := os.WriteFile(path, []byte(fixture), 0o644); err != nil {
		t.Fatal(err)
	}
	runTestGit(t, root, "init", "-q")
	runTestGit(t, root, "config", "user.email", "test@example.com")
	runTestGit(t, root, "config", "user.name", "Test")
	runTestGit(t, root, "add", ".")
	runTestGit(t, root, "commit", "-qm", "baseline")
	changed := fixture[:len(fixture)-2] + "\treturn errors.New(\"changed\")\n}\n"
	if err := os.WriteFile(path, []byte(changed), 0o644); err != nil {
		t.Fatal(err)
	}
	snapshot, err := buildSnapshot(root, path, 30)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Roots) != 1 || snapshot.Roots[0].Kind != "method" || snapshot.Roots[0].Name != "Save" {
		t.Fatalf("unexpected roots: %#v", snapshot.Roots)
	}
}

func TestUntrackedFileProducesTopLevelRoots(t *testing.T) {
	root := t.TempDir()
	runTestGit(t, root, "init", "-q")
	runTestGit(t, root, "config", "user.email", "test@example.com")
	runTestGit(t, root, "config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(root, "base.go"), []byte("package sample\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runTestGit(t, root, "add", ".")
	runTestGit(t, root, "commit", "-qm", "baseline")

	untracked := `package sample

const A = 1
var B = 2
func C() {}
`
	if err := os.WriteFile(filepath.Join(root, "new.go"), []byte(untracked), 0o644); err != nil {
		t.Fatal(err)
	}

	snapshot, err := buildSnapshot(root, "", 0)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, root := range snapshot.Roots {
		got[root.Kind+":"+root.Name] = true
	}
	for _, key := range []string{"const:A", "var:B", "function:C"} {
		if !got[key] {
			t.Fatalf("missing untracked root %s: %#v", key, snapshot.Roots)
		}
	}
}

func TestDeletionOnlyUsesBaselineDeclaration(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "sample.go")
	original := `package sample

func Keep() {}
func Removed() { println("gone") }
`
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatal(err)
	}
	runTestGit(t, root, "init", "-q")
	runTestGit(t, root, "config", "user.email", "test@example.com")
	runTestGit(t, root, "config", "user.name", "Test")
	runTestGit(t, root, "add", ".")
	runTestGit(t, root, "commit", "-qm", "baseline")

	if err := os.WriteFile(path, []byte("package sample\n\nfunc Keep() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	snapshot, err := buildSnapshot(root, "", 0)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, root := range snapshot.Roots {
		if root.Name == "Removed" {
			found = true
			if !root.Deleted || !root.Baseline {
				t.Fatalf("deleted root is not baseline: %#v", root)
			}
		}
	}
	if !found {
		t.Fatalf("missing deleted baseline declaration: %#v", snapshot.Roots)
	}
}

func TestImplicitConstKeepsExactIdentity(t *testing.T) {
	source := `package sample

const (
	A = iota
	B
	C
)
`
	parsed, err := parseFile("sample.go", []byte(source), false)
	if err != nil {
		t.Fatal(err)
	}
	b := findSymbol(parsed.index, "const", "B")
	if b == nil || !b.Implicit {
		t.Fatalf("implicit const B not indexed: %#v", b)
	}
	if b.Name != "B" || b.Qualified != "B" {
		t.Fatalf("implicit const identity was not exact: %#v", b)
	}
}
