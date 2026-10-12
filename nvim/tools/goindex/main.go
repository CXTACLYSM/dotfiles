package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const protocolVersion = 3

type Request struct {
	Mode        string `json:"mode"`
	Root        string `json:"root"`
	Path        string `json:"path,omitempty"`
	Content     string `json:"content,omitempty"`
	CurrentFile string `json:"current_file,omitempty"`
	CurrentLine int    `json:"current_line,omitempty"`
}

type Envelope struct {
	Version  int        `json:"version"`
	OK       bool       `json:"ok"`
	Error    string     `json:"error,omitempty"`
	Snapshot *Snapshot  `json:"snapshot,omitempty"`
	File     *FileIndex `json:"file,omitempty"`
}

type Snapshot struct {
	Root      string                `json:"root"`
	GitHead   string                `json:"git_head,omitempty"`
	Signature string                `json:"signature"`
	Diff      string                `json:"diff"`
	Untracked []string              `json:"untracked"`
	Roots     []Symbol              `json:"roots"`
	Files     map[string]*FileIndex `json:"files"`
	Warnings  []string              `json:"warnings,omitempty"`
}

type FileIndex struct {
	Path      string   `json:"path"`
	Package   string   `json:"package"`
	IsTest    bool     `json:"is_test"`
	Generated bool     `json:"generated"`
	Baseline  bool     `json:"baseline,omitempty"`
	SHA256    string   `json:"sha256"`
	Source    string   `json:"source"`
	Symbols   []Symbol `json:"symbols"`
}

type Symbol struct {
	ID        string   `json:"id"`
	Path      string   `json:"path"`
	Package   string   `json:"package"`
	Kind      string   `json:"kind"`
	Name      string   `json:"name"`
	Receiver  string   `json:"receiver,omitempty"`
	Qualified string   `json:"qualified"`
	TopLevel  bool     `json:"top_level"`
	OwnerID   string   `json:"owner_id,omitempty"`
	MemberIDs []string `json:"member_ids,omitempty"`

	IsTest    bool `json:"is_test"`
	Generated bool `json:"generated"`
	Baseline  bool `json:"baseline,omitempty"`
	Deleted   bool `json:"deleted,omitempty"`
	Implicit  bool `json:"implicit,omitempty"`

	StartLine   int `json:"start_line"`
	StartCol    int `json:"start_col"`
	EndLine     int `json:"end_line"`
	EndCol      int `json:"end_col"`
	NameLine    int `json:"name_line"`
	NameCol     int `json:"name_col"`
	NameEndLine int `json:"name_end_line"`
	NameEndCol  int `json:"name_end_col"`

	StartOffset     int `json:"start_offset"`
	EndOffset       int `json:"end_offset"`
	NameStartOffset int `json:"name_start_offset"`
	NameEndOffset   int `json:"name_end_offset"`
	ContainerStart  int `json:"container_start_offset"`
	ContainerEnd    int `json:"container_end_offset"`

	HeaderSource string       `json:"header_source,omitempty"`
	FooterSource string       `json:"footer_source,omitempty"`
	TypeSource   string       `json:"type_source,omitempty"`
	Occurrences  []Occurrence `json:"occurrences,omitempty"`
}

type Occurrence struct {
	ID               string `json:"id"`
	Name             string `json:"name"`
	Kind             string `json:"kind"`
	Priority         int    `json:"priority"`
	Line             int    `json:"line"`
	Col              int    `json:"col"`
	EndLine          int    `json:"end_line"`
	EndCol           int    `json:"end_col"`
	Offset           int    `json:"offset"`
	EndOffset        int    `json:"end_offset"`
	Local            bool   `json:"local,omitempty"`
	Binding          bool   `json:"binding,omitempty"`
	BuiltinCandidate bool   `json:"builtin_candidate,omitempty"`
}

type hunk struct {
	OldStart int
	OldCount int
	NewStart int
	NewCount int
}

type fileChange struct {
	OldPath string
	NewPath string
	Hunks   []hunk
}

type parsedFile struct {
	index   *FileIndex
	fset    *token.FileSet
	tokFile *token.File
	file    *ast.File
	source  []byte
	byID    map[string]*symbolInternal
}

type symbolInternal struct {
	symbol Symbol
	node   ast.Node
}

var predeclared = map[string]bool{
	"any": true, "bool": true, "byte": true, "comparable": true,
	"complex64": true, "complex128": true, "error": true,
	"float32": true, "float64": true, "int": true, "int8": true,
	"int16": true, "int32": true, "int64": true, "rune": true,
	"string": true, "uint": true, "uint8": true, "uint16": true,
	"uint32": true, "uint64": true, "uintptr": true,
	"true": true, "false": true, "iota": true, "nil": true,
	"append": true, "cap": true, "clear": true, "close": true,
	"complex": true, "copy": true, "delete": true, "imag": true,
	"len": true, "make": true, "max": true, "min": true, "new": true,
	"panic": true, "print": true, "println": true, "real": true,
	"recover": true,
}

func main() {
	var req Request
	if err := json.NewDecoder(os.Stdin).Decode(&req); err != nil {
		writeEnvelope(Envelope{Version: protocolVersion, OK: false, Error: "decode request: " + err.Error()}, 2)
		return
	}
	env := handle(req)
	code := 0
	if !env.OK {
		code = 1
	}
	writeEnvelope(env, code)
}

func writeEnvelope(env Envelope, code int) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(env); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(3)
	}
	if code != 0 {
		os.Exit(code)
	}
}

func handle(req Request) Envelope {
	root, err := normalizeRoot(req.Root)
	if err != nil {
		return Envelope{Version: protocolVersion, OK: false, Error: err.Error()}
	}
	switch req.Mode {
	case "snapshot":
		snapshot, err := buildSnapshot(root, req.CurrentFile, req.CurrentLine)
		if err != nil {
			return Envelope{Version: protocolVersion, OK: false, Error: err.Error()}
		}
		return Envelope{Version: protocolVersion, OK: true, Snapshot: snapshot}
	case "inspect_file":
		file, err := inspectFile(root, req.Path, req.Content)
		if err != nil {
			return Envelope{Version: protocolVersion, OK: false, Error: err.Error()}
		}
		return Envelope{Version: protocolVersion, OK: true, File: file}
	default:
		return Envelope{Version: protocolVersion, OK: false, Error: "unsupported mode: " + req.Mode}
	}
}

func normalizeRoot(root string) (string, error) {
	if strings.TrimSpace(root) == "" {
		return "", errors.New("root is required")
	}
	abs, err := filepath.Abs(root)
	if err != nil {
		return "", err
	}
	return filepath.Clean(abs), nil
}

func relativePath(root, path string) (string, error) {
	if !filepath.IsAbs(path) {
		path = filepath.Join(root, path)
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	rel, err := filepath.Rel(root, abs)
	if err != nil {
		return "", err
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("path %q is outside root", path)
	}
	return filepath.ToSlash(filepath.Clean(rel)), nil
}

func hashBytes(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func stableID(parts ...string) string {
	return hashBytes([]byte(strings.Join(parts, "|")))[:24]
}

func runGit(root string, args ...string) (string, error) {
	cmdArgs := append([]string{"-C", root}, args...)
	cmd := exec.Command("git", cmdArgs...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

func isGenerated(source []byte) bool {
	lines := bytes.Split(source, []byte("\n"))
	limit := len(lines)
	if limit > 20 {
		limit = 20
	}
	for _, line := range lines[:limit] {
		text := string(line)
		if strings.Contains(text, "Code generated") && strings.Contains(text, "DO NOT EDIT.") {
			return true
		}
	}
	return false
}

func position(tokFile *token.File, fset *token.FileSet, pos token.Pos) (line, col, offset int) {
	p := fset.PositionFor(pos, false)
	return p.Line, p.Column, tokFile.Offset(pos)
}

func sliceSource(source []byte, start, end int) string {
	if start < 0 {
		start = 0
	}
	if end < start {
		end = start
	}
	if start > len(source) {
		start = len(source)
	}
	if end > len(source) {
		end = len(source)
	}
	return string(source[start:end])
}

func formatNode(fset *token.FileSet, node any) string {
	var out bytes.Buffer
	if err := format.Node(&out, fset, node); err != nil {
		return ""
	}
	return out.String()
}

func makeSymbol(pf *parsedFile, kind, name string, node ast.Node, nameNode *ast.Ident, topLevel bool, ownerID string, container ast.Node) Symbol {
	sl, sc, so := position(pf.tokFile, pf.fset, node.Pos())
	el, ec, eo := position(pf.tokFile, pf.fset, node.End())
	nl, nc, no := position(pf.tokFile, pf.fset, nameNode.Pos())
	nel, nec, neo := position(pf.tokFile, pf.fset, nameNode.End())
	cs, ce := so, eo
	if container != nil {
		cs = pf.tokFile.Offset(container.Pos())
		ce = pf.tokFile.Offset(container.End())
	}
	symbol := Symbol{
		Path: pf.index.Path, Package: pf.index.Package, Kind: kind, Name: name,
		Qualified: name, TopLevel: topLevel, OwnerID: ownerID,
		IsTest: pf.index.IsTest, Generated: pf.index.Generated, Baseline: pf.index.Baseline,
		StartLine: sl, StartCol: sc, EndLine: el, EndCol: ec,
		NameLine: nl, NameCol: nc, NameEndLine: nel, NameEndCol: nec,
		StartOffset: so, EndOffset: eo, NameStartOffset: no, NameEndOffset: neo,
		ContainerStart: cs, ContainerEnd: ce,
	}
	symbol.ID = stableID(symbol.Path, kind, name, strconv.Itoa(so), strconv.Itoa(eo))
	return symbol
}

func receiverText(fset *token.FileSet, receiver *ast.FieldList) string {
	if receiver == nil || len(receiver.List) == 0 {
		return ""
	}
	return strings.TrimSpace(formatNode(fset, receiver.List[0].Type))
}

func typeKind(expr ast.Expr) string {
	switch expr.(type) {
	case *ast.StructType:
		return "struct"
	case *ast.InterfaceType:
		return "interface"
	default:
		return "type"
	}
}

func embeddedName(expr ast.Expr, fset *token.FileSet) string {
	switch value := expr.(type) {
	case *ast.Ident:
		return value.Name
	case *ast.SelectorExpr:
		return value.Sel.Name
	case *ast.StarExpr:
		return embeddedName(value.X, fset)
	case *ast.IndexExpr:
		return embeddedName(value.X, fset)
	case *ast.IndexListExpr:
		return embeddedName(value.X, fset)
	default:
		return strings.TrimSpace(formatNode(fset, expr))
	}
}

func addMember(pf *parsedFile, owner *symbolInternal, field *ast.Field, kind string) {
	names := field.Names
	if len(names) == 0 {
		names = []*ast.Ident{{NamePos: field.Type.Pos(), Name: embeddedName(field.Type, pf.fset)}}
	}
	for _, name := range names {
		if name == nil || name.Name == "" {
			continue
		}
		member := makeSymbol(pf, kind, name.Name, field, name, false, owner.symbol.ID, field)
		member.Qualified = owner.symbol.Name + "." + name.Name
		member.TypeSource = strings.TrimSpace(formatNode(pf.fset, field.Type))
		internal := &symbolInternal{symbol: member, node: field}
		pf.byID[member.ID] = internal
		pf.index.Symbols = append(pf.index.Symbols, member)
		owner.symbol.MemberIDs = append(owner.symbol.MemberIDs, member.ID)
	}
}

func parseFile(rel string, source []byte, baseline bool) (*parsedFile, error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, rel, source, parser.ParseComments|parser.AllErrors)
	if err != nil {
		return nil, fmt.Errorf("parse %s: %w", rel, err)
	}
	tokFile := fset.File(file.Pos())
	if tokFile == nil {
		return nil, fmt.Errorf("missing token file for %s", rel)
	}
	index := &FileIndex{
		Path: rel, Package: file.Name.Name, IsTest: strings.HasSuffix(rel, "_test.go"),
		Generated: isGenerated(source), Baseline: baseline, SHA256: hashBytes(source), Source: string(source),
	}
	pf := &parsedFile{index: index, fset: fset, tokFile: tokFile, file: file, source: source, byID: map[string]*symbolInternal{}}

	for _, declaration := range file.Decls {
		switch decl := declaration.(type) {
		case *ast.FuncDecl:
			kind := "function"
			receiver := receiverText(fset, decl.Recv)
			if receiver != "" {
				kind = "method"
			}
			symbol := makeSymbol(pf, kind, decl.Name.Name, decl, decl.Name, true, "", decl)
			symbol.Receiver = receiver
			if receiver != "" {
				symbol.Qualified = "(" + receiver + ")." + decl.Name.Name
			}
			pf.byID[symbol.ID] = &symbolInternal{symbol: symbol, node: decl}
			index.Symbols = append(index.Symbols, symbol)
		case *ast.GenDecl:
			for _, rawSpec := range decl.Specs {
				switch spec := rawSpec.(type) {
				case *ast.TypeSpec:
					kind := typeKind(spec.Type)
					symbol := makeSymbol(pf, kind, spec.Name.Name, spec, spec.Name, true, "", decl)
					symbol.TypeSource = strings.TrimSpace(formatNode(fset, spec.Type))
					internal := &symbolInternal{symbol: symbol, node: spec}
					pf.byID[symbol.ID] = internal
					index.Symbols = append(index.Symbols, symbol)
					switch typ := spec.Type.(type) {
					case *ast.StructType:
						open := tokFile.Offset(typ.Fields.Opening)
						internal.symbol.HeaderSource = "type " + sliceSource(source, symbol.StartOffset, min(open+1, len(source)))
						internal.symbol.FooterSource = "}"
						for _, field := range typ.Fields.List {
							addMember(pf, internal, field, "field")
						}
					case *ast.InterfaceType:
						open := tokFile.Offset(typ.Methods.Opening)
						internal.symbol.HeaderSource = "type " + sliceSource(source, symbol.StartOffset, min(open+1, len(source)))
						internal.symbol.FooterSource = "}"
						for _, field := range typ.Methods.List {
							memberKind := "interface_method"
							if len(field.Names) == 0 {
								memberKind = "embedded_interface"
							}
							addMember(pf, internal, field, memberKind)
						}
					}
				case *ast.ValueSpec:
					kind := "var"
					if decl.Tok == token.CONST {
						kind = "const"
					}
					for _, name := range spec.Names {
						symbol := makeSymbol(pf, kind, name.Name, spec, name, true, "", decl)
						symbol.Implicit = decl.Tok == token.CONST && len(spec.Values) == 0
						if spec.Type != nil {
							symbol.TypeSource = strings.TrimSpace(formatNode(fset, spec.Type))
						}
						pf.byID[symbol.ID] = &symbolInternal{symbol: symbol, node: spec}
						index.Symbols = append(index.Symbols, symbol)
					}
				}
			}
		}
	}

	for i := range index.Symbols {
		if internal := pf.byID[index.Symbols[i].ID]; internal != nil {
			index.Symbols[i] = internal.symbol
		}
	}
	for i := range index.Symbols {
		internal := pf.byID[index.Symbols[i].ID]
		if internal == nil {
			continue
		}
		internal.symbol.Occurrences = collectOccurrences(pf, internal)
		index.Symbols[i] = internal.symbol
	}
	sort.SliceStable(index.Symbols, func(i, j int) bool {
		if index.Symbols[i].StartOffset == index.Symbols[j].StartOffset {
			if index.Symbols[i].TopLevel != index.Symbols[j].TopLevel {
				return index.Symbols[i].TopLevel
			}
			return index.Symbols[i].Name < index.Symbols[j].Name
		}
		return index.Symbols[i].StartOffset < index.Symbols[j].StartOffset
	})
	return pf, nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func unwrapCallTarget(expr ast.Expr) *ast.Ident {
	switch value := expr.(type) {
	case *ast.Ident:
		return value
	case *ast.SelectorExpr:
		return value.Sel
	case *ast.IndexExpr:
		return unwrapCallTarget(value.X)
	case *ast.IndexListExpr:
		return unwrapCallTarget(value.X)
	case *ast.ParenExpr:
		return unwrapCallTarget(value.X)
	default:
		return nil
	}
}

func bindingPositions(node ast.Node) map[token.Pos]bool {
	bindings := map[token.Pos]bool{}
	markFields := func(fields *ast.FieldList) {
		if fields == nil {
			return
		}
		for _, field := range fields.List {
			for _, name := range field.Names {
				bindings[name.Pos()] = true
			}
		}
	}
	ast.Inspect(node, func(raw ast.Node) bool {
		switch value := raw.(type) {
		case *ast.FuncDecl:
			bindings[value.Name.Pos()] = true
			markFields(value.Recv)
			markFields(value.Type.Params)
			markFields(value.Type.Results)
		case *ast.FuncLit:
			markFields(value.Type.Params)
			markFields(value.Type.Results)
		case *ast.AssignStmt:
			if value.Tok == token.DEFINE {
				for _, expr := range value.Lhs {
					if id, ok := expr.(*ast.Ident); ok {
						bindings[id.Pos()] = true
					}
				}
			}
		case *ast.RangeStmt:
			if value.Tok == token.DEFINE {
				if id, ok := value.Key.(*ast.Ident); ok {
					bindings[id.Pos()] = true
				}
				if id, ok := value.Value.(*ast.Ident); ok {
					bindings[id.Pos()] = true
				}
			}
		case *ast.ValueSpec:
			for _, name := range value.Names {
				bindings[name.Pos()] = true
			}
		case *ast.TypeSpec:
			bindings[value.Name.Pos()] = true
		case *ast.Field:
			for _, name := range value.Names {
				bindings[name.Pos()] = true
			}
		case *ast.LabeledStmt:
			bindings[value.Label.Pos()] = true
		}
		return true
	})
	return bindings
}

func selectorReceiverPositions(node ast.Node) map[token.Pos]bool {
	positions := map[token.Pos]bool{}
	ast.Inspect(node, func(raw ast.Node) bool {
		selector, ok := raw.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		ast.Inspect(selector.X, func(inner ast.Node) bool {
			if id, ok := inner.(*ast.Ident); ok {
				positions[id.Pos()] = true
			}
			return true
		})
		return true
	})
	return positions
}

func typeRanges(node ast.Node) [][2]token.Pos {
	var ranges [][2]token.Pos
	add := func(raw ast.Node) {
		if raw != nil {
			ranges = append(ranges, [2]token.Pos{raw.Pos(), raw.End()})
		}
	}
	ast.Inspect(node, func(raw ast.Node) bool {
		switch value := raw.(type) {
		case *ast.Field:
			add(value.Type)
		case *ast.TypeSpec:
			add(value.Type)
		case *ast.CompositeLit:
			add(value.Type)
		case *ast.TypeAssertExpr:
			add(value.Type)
		case *ast.ArrayType, *ast.MapType, *ast.ChanType, *ast.StructType, *ast.InterfaceType, *ast.FuncType:
			add(raw)
		}
		return true
	})
	return ranges
}

func positionInRanges(pos token.Pos, ranges [][2]token.Pos) bool {
	for _, item := range ranges {
		if pos >= item[0] && pos < item[1] {
			return true
		}
	}
	return false
}

func collectOccurrences(pf *parsedFile, internal *symbolInternal) []Occurrence {
	node := internal.node
	bindings := bindingPositions(node)
	selectorReceivers := selectorReceiverPositions(node)
	types := typeRanges(node)
	rootStart, rootEnd := node.Pos(), node.End()
	byOffset := map[int]Occurrence{}

	put := func(id *ast.Ident, kind string, priority int) {
		if id == nil || id.Name == "" || id.Name == "_" {
			return
		}
		line, col, offset := position(pf.tokFile, pf.fset, id.Pos())
		endLine, endCol, endOffset := position(pf.tokFile, pf.fset, id.End())
		occurrence := Occurrence{
			Name: id.Name, Kind: kind, Priority: priority,
			Line: line, Col: col, EndLine: endLine, EndCol: endCol,
			Offset: offset, EndOffset: endOffset,
			Binding: bindings[id.Pos()], BuiltinCandidate: predeclared[id.Name],
		}
		if id.Obj != nil && id.Obj.Pos() >= rootStart && id.Obj.Pos() < rootEnd && id.Obj.Pos() != id.Pos() {
			occurrence.Local = true
		}
		occurrence.ID = stableID(pf.index.Path, "occurrence:"+kind, id.Name, strconv.Itoa(offset), strconv.Itoa(endOffset))
		previous, exists := byOffset[offset]
		if !exists || priority > previous.Priority {
			byOffset[offset] = occurrence
		}
	}

	ast.Inspect(node, func(raw ast.Node) bool {
		switch value := raw.(type) {
		case *ast.CallExpr:
			put(unwrapCallTarget(value.Fun), "call", 100)
		case *ast.SelectorExpr:
			put(value.Sel, "selector", 90)
		case *ast.KeyValueExpr:
			if id, ok := value.Key.(*ast.Ident); ok {
				put(id, "field_key", 85)
			}
		}
		return true
	})

	ast.Inspect(node, func(raw ast.Node) bool {
		id, ok := raw.(*ast.Ident)
		if !ok {
			return true
		}
		if bindings[id.Pos()] || selectorReceivers[id.Pos()] {
			return true
		}
		kind, priority := "identifier", 60
		if positionInRanges(id.Pos(), types) {
			kind, priority = "type", 80
		}
		put(id, kind, priority)
		return true
	})

	result := make([]Occurrence, 0, len(byOffset))
	for _, occurrence := range byOffset {
		result = append(result, occurrence)
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Priority == result[j].Priority {
			return result[i].Offset < result[j].Offset
		}
		return result[i].Priority > result[j].Priority
	})
	return result
}

func symbolsIntersecting(index *FileIndex, start, count int) []Symbol {
	if count <= 0 {
		return nil
	}
	end := start + count - 1
	var result []Symbol
	for _, symbol := range index.Symbols {
		if !symbol.TopLevel {
			continue
		}
		if start <= symbol.EndLine && end >= symbol.StartLine {
			result = append(result, symbol)
		}
	}
	return result
}

func symbolContainingLine(index *FileIndex, line int) *Symbol {
	var best *Symbol
	bestSpan := int(^uint(0) >> 1)
	for i := range index.Symbols {
		symbol := &index.Symbols[i]
		if !symbol.TopLevel || line < symbol.StartLine || line > symbol.EndLine {
			continue
		}
		span := symbol.EndLine - symbol.StartLine
		if best == nil || span < bestSpan {
			best = symbol
			bestSpan = span
		}
	}
	return best
}

func parseHunkRange(raw string) (int, int) {
	raw = strings.TrimLeft(raw, "+-")
	parts := strings.SplitN(raw, ",", 2)
	start, _ := strconv.Atoi(parts[0])
	count := 1
	if len(parts) == 2 {
		count, _ = strconv.Atoi(parts[1])
	}
	return start, count
}

func parseDiff(text string) []fileChange {
	var changes []fileChange
	var current *fileChange
	for _, line := range strings.Split(text, "\n") {
		switch {
		case strings.HasPrefix(line, "diff --git "):
			changes = append(changes, fileChange{})
			current = &changes[len(changes)-1]
		case current != nil && strings.HasPrefix(line, "--- "):
			current.OldPath = strings.TrimSpace(strings.TrimPrefix(line, "--- "))
		case current != nil && strings.HasPrefix(line, "+++ "):
			current.NewPath = strings.TrimSpace(strings.TrimPrefix(line, "+++ "))
		case current != nil && strings.HasPrefix(line, "@@ "):
			parts := strings.Fields(line)
			if len(parts) >= 3 {
				oldStart, oldCount := parseHunkRange(parts[1])
				newStart, newCount := parseHunkRange(parts[2])
				current.Hunks = append(current.Hunks, hunk{OldStart: oldStart, OldCount: oldCount, NewStart: newStart, NewCount: newCount})
			}
		}
	}
	return changes
}

func currentSource(root, rel string) ([]byte, error) {
	return os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
}

func baselineSource(root, rel string) ([]byte, error) {
	text, err := runGit(root, "show", "HEAD:"+rel)
	return []byte(text), err
}

func syntheticHunk(index *FileIndex, start, count int) Symbol {
	lines := strings.Split(index.Source, "\n")
	if start < 1 {
		start = 1
	}
	end := start + max(count, 1) - 1
	if end > len(lines) {
		end = len(lines)
	}
	low := max(1, start-3)
	high := min(len(lines), end+3)
	startOffset := 0
	for i := 1; i < low; i++ {
		startOffset += len(lines[i-1]) + 1
	}
	endOffset := startOffset
	for i := low; i <= high; i++ {
		endOffset += len(lines[i-1])
		if i < high {
			endOffset++
		}
	}
	name := fmt.Sprintf("file_hunk@%d", start)
	return Symbol{
		ID:   stableID(index.Path, "file_hunk", name, strconv.Itoa(startOffset), strconv.Itoa(endOffset)),
		Path: index.Path, Package: index.Package, Kind: "file_hunk", Name: name, Qualified: name, TopLevel: true,
		IsTest: index.IsTest, Generated: index.Generated, Baseline: index.Baseline,
		StartLine: low, StartCol: 1, EndLine: high, EndCol: 1,
		NameLine: start, NameCol: 1, NameEndLine: start, NameEndCol: 1,
		StartOffset: startOffset, EndOffset: endOffset, NameStartOffset: startOffset, NameEndOffset: startOffset,
		ContainerStart: startOffset, ContainerEnd: endOffset,
	}
}

func buildSnapshot(root, currentFile string, currentLine int) (*Snapshot, error) {
	diff, diffErr := runGit(root, "-c", "core.quotePath=false", "diff", "--no-ext-diff", "--unified=0", "--no-prefix", "--no-renames", "HEAD", "--", "*.go")
	head, headErr := runGit(root, "rev-parse", "HEAD")
	untrackedText, untrackedErr := runGit(root, "-c", "core.quotePath=false", "ls-files", "-z", "--others", "--exclude-standard", "--", "*.go")
	snapshot := &Snapshot{Root: root, Diff: diff, Files: map[string]*FileIndex{}}
	if headErr == nil {
		snapshot.GitHead = strings.TrimSpace(head)
	}
	if diffErr != nil {
		snapshot.Warnings = append(snapshot.Warnings, diffErr.Error())
		diff = ""
		snapshot.Diff = ""
	}
	if untrackedErr != nil {
		snapshot.Warnings = append(snapshot.Warnings, untrackedErr.Error())
		untrackedText = ""
	}
	for _, path := range strings.Split(untrackedText, "\x00") {
		if path == "" {
			continue
		}
		snapshot.Untracked = append(snapshot.Untracked, filepath.ToSlash(path))
	}
	sort.Strings(snapshot.Untracked)

	roots := map[string]Symbol{}
	for _, change := range parseDiff(diff) {
		if change.NewPath != "" && change.NewPath != "/dev/null" && strings.HasSuffix(change.NewPath, ".go") {
			source, err := currentSource(root, change.NewPath)
			if err != nil {
				snapshot.Warnings = append(snapshot.Warnings, err.Error())
			} else if parsed, err := parseFile(change.NewPath, source, false); err != nil {
				snapshot.Warnings = append(snapshot.Warnings, err.Error())
			} else {
				snapshot.Files[change.NewPath] = parsed.index
				for _, changed := range change.Hunks {
					if changed.NewCount <= 0 {
						continue
					}
					found := symbolsIntersecting(parsed.index, changed.NewStart, changed.NewCount)
					if len(found) == 0 {
						found = []Symbol{syntheticHunk(parsed.index, changed.NewStart, changed.NewCount)}
					}
					for _, symbol := range found {
						roots[symbol.ID] = symbol
					}
				}
			}
		}
		for _, changed := range change.Hunks {
			if changed.NewCount != 0 || change.OldPath == "" || change.OldPath == "/dev/null" {
				continue
			}
			source, err := baselineSource(root, change.OldPath)
			if err != nil {
				snapshot.Warnings = append(snapshot.Warnings, err.Error())
				continue
			}
			parsed, err := parseFile(change.OldPath, source, true)
			if err != nil {
				snapshot.Warnings = append(snapshot.Warnings, err.Error())
				continue
			}
			key := change.OldPath + "#HEAD"
			snapshot.Files[key] = parsed.index
			found := symbolsIntersecting(parsed.index, changed.OldStart, max(changed.OldCount, 1))
			if len(found) == 0 {
				found = []Symbol{syntheticHunk(parsed.index, changed.OldStart, max(changed.OldCount, 1))}
			}
			for _, symbol := range found {
				symbol.Deleted = true
				symbol.Baseline = true
				roots[symbol.ID] = symbol
			}
		}
	}

	for _, rel := range snapshot.Untracked {
		source, err := currentSource(root, rel)
		if err != nil {
			snapshot.Warnings = append(snapshot.Warnings, err.Error())
			continue
		}
		parsed, err := parseFile(rel, source, false)
		if err != nil {
			snapshot.Warnings = append(snapshot.Warnings, err.Error())
			continue
		}
		snapshot.Files[rel] = parsed.index
		added := false
		for _, symbol := range parsed.index.Symbols {
			if symbol.TopLevel {
				roots[symbol.ID] = symbol
				added = true
			}
		}
		if !added {
			symbol := syntheticHunk(parsed.index, 1, len(strings.Split(parsed.index.Source, "\n")))
			roots[symbol.ID] = symbol
		}
	}

	if len(roots) == 0 && currentFile != "" && currentLine > 0 {
		rel, err := relativePath(root, currentFile)
		if err == nil {
			if source, err := currentSource(root, rel); err == nil {
				if parsed, err := parseFile(rel, source, false); err == nil {
					snapshot.Files[rel] = parsed.index
					if symbol := symbolContainingLine(parsed.index, currentLine); symbol != nil {
						roots[symbol.ID] = *symbol
					}
				}
			}
		}
	}

	for _, symbol := range roots {
		snapshot.Roots = append(snapshot.Roots, symbol)
	}
	sort.Slice(snapshot.Roots, func(i, j int) bool {
		if snapshot.Roots[i].Path == snapshot.Roots[j].Path {
			return snapshot.Roots[i].StartOffset < snapshot.Roots[j].StartOffset
		}
		return snapshot.Roots[i].Path < snapshot.Roots[j].Path
	})

	var identity bytes.Buffer
	identity.WriteString(snapshot.GitHead)
	identity.WriteByte('\n')
	identity.WriteString(snapshot.Diff)
	identity.WriteString("\n--UNTRACKED--\n")
	for _, rel := range snapshot.Untracked {
		identity.WriteString(rel)
		identity.WriteByte('\n')
		if source, err := currentSource(root, rel); err == nil {
			identity.WriteString(hashBytes(source))
			identity.WriteByte('\n')
		}
	}
	snapshot.Signature = hashBytes(identity.Bytes())
	return snapshot, nil
}

func inspectFile(root, path, content string) (*FileIndex, error) {
	rel, err := relativePath(root, path)
	if err != nil {
		return nil, err
	}
	var source []byte
	if content != "" {
		source = []byte(content)
	} else {
		source, err = currentSource(root, rel)
		if err != nil {
			return nil, err
		}
	}
	parsed, err := parseFile(rel, source, false)
	if err != nil {
		return nil, err
	}
	return parsed.index, nil
}
