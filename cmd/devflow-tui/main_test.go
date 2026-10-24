package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func testModel() model { return newModel(func(map[string]any) tea.Cmd { return nil }) }
func key(m model, code rune, mod tea.KeyMod) (model, tea.Cmd) {
	n, cmd := m.Update(tea.KeyPressMsg{Code: code, Mod: mod})
	return n.(model), cmd
}
func TestMetadataAndUnknownSpend(t *testing.T) {
	m := testModel()
	m.state = state{Title: "Fix login", Model: "test-model", Effort: "high", Provider: "codex", Status: "running", CreatedAt: 100, TurnStarted: 150}
	m.clock = time.Unix(200, 0)
	v := ansi.Strip(m.View().Content)
	for _, want := range []string{"Fix login", "test-model", "effort: high", "spend: not reported", "turn: 50s", "session age: 1m40s"} {
		if !strings.Contains(v, want) {
			t.Fatalf("missing %q in %s", want, v)
		}
	}
	if strings.Contains(v, "$0") {
		t.Fatal("unknown is not zero")
	}
	cost := .1245
	m.state.Cost = &cost
	m.state.CostScope = "SDK estimate"
	if !strings.Contains(m.View().Content, "~$0.1245 (SDK estimate)") {
		t.Fatal("cost must be labelled")
	}
}
func TestLayoutWidths(t *testing.T) {
	for _, width := range []int{35, 60, 90, 160} {
		m := testModel()
		n, _ := m.Update(tea.WindowSizeMsg{Width: width, Height: 24})
		m = n.(model)
		text := strings.Repeat("世界 hello 🧪 output\n", 1000)
		n, _ = m.Update(snapshot{Text: &text})
		m = n.(model)
		lines := strings.Split(m.View().Content, "\n")
		if len(lines) != 24 {
			t.Fatalf("width %d: %d rows", width, len(lines))
		}
		for _, line := range lines {
			if ansi.StringWidth(line) > width {
				t.Fatalf("line exceeds %d: %q", width, line)
			}
		}
	}
}
func TestSanitizeEveryRemoteSurface(t *testing.T) {
	attack := "\x1b]52;c;c2VjcmV0\x07\x1b[31mhello\x9b\x00"
	if safe(attack) != "hello�" && safe(attack) != "hello" {
		t.Fatalf("sanitize: %q", safe(attack))
	}
	m := testModel()
	m.state.Title = attack
	m.state.Error = attack
	n, _ := m.Update(snapshot{Text: &attack})
	m = n.(model)
	if strings.Contains(m.transcript, "\x1b") || strings.Contains(m.View().Content, "52;") {
		t.Fatal("terminal injection")
	}
}
func TestApprovalHasNoDefaultAndCanDeny(t *testing.T) {
	var sent map[string]any
	m := newModel(func(r map[string]any) tea.Cmd { sent = r; return nil })
	m.state.Pending = map[string]interaction{"id": {Method: "item/commandExecution/requestApproval", Params: json.RawMessage(`{"command":"rm example","reason":"test"}`)}}
	m.openQuestion()
	if _, err := m.reply(); err == nil || sent != nil {
		t.Fatal("empty answer approved")
	}
	m.input.SetValue("1")
	_, err := m.reply()
	if err != nil {
		t.Fatal(err)
	}
	if sent["reply"].(map[string]any)["allow"] != false {
		t.Fatal("must deny")
	}
}
func TestQuestionMultiSelectAndInvalidation(t *testing.T) {
	var sent map[string]any
	m := newModel(func(r map[string]any) tea.Cmd { sent = r; return nil })
	m.state.Pending = map[string]interaction{"question": {Method: "AskUserQuestion", Params: json.RawMessage(`{"questions":[{"question":"Choose","multiSelect":true,"options":[{"label":"one"},{"label":"two"}]}]}`)}}
	m.openQuestion()
	m.input.SetValue("1,2")
	_, err := m.reply()
	if err != nil {
		t.Fatal(err)
	}
	a := sent["reply"].(map[string]any)["answers"].(map[string]any)["Choose"].([]string)
	if strings.Join(a, ",") != "one,two" {
		t.Fatal(a)
	}
	m.openQuestion()
	n, _ := m.Update(snapshot{State: &state{}})
	if n.(model).answer != nil {
		t.Fatal("stale request remains answerable")
	}
}
func TestDetachWaitsForLocalDurability(t *testing.T) {
	m := testModel()
	m.submit(map[string]any{"op": "command", "text": "task"})
	m, cmd := key(m, 'd', tea.ModCtrl)
	if cmd != nil || !m.detaching {
		t.Fatal("detached before input persisted")
	}
	id := 1
	_, cmd = m.Update(snapshot{Ack: &id})
	if cmd == nil {
		t.Fatal("did not detach after ack")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatal("expected quit")
	}
}
func TestTranscriptBoundAndScrollAnchor(t *testing.T) {
	m := testModel()
	text := strings.Repeat("line\n", 50000)
	n, _ := m.Update(snapshot{Text: &text})
	m = n.(model)
	if len([]rune(m.transcript)) > 150000 {
		t.Fatal("unbounded history")
	}
	m.log.PageUp()
	offset := m.log.YOffset()
	text = m.transcript + "new\n"
	n, _ = m.Update(snapshot{Text: &text})
	m = n.(model)
	if m.log.YOffset() != offset {
		t.Fatal("new output moved reader away from history")
	}
	n, _ = m.Update(tick(time.Now()))
	m = n.(model)
	if m.log.YOffset() != offset {
		t.Fatal("clock moved history")
	}
}
func TestTurnTimerStops(t *testing.T) {
	if got := elapsed(100, 120, time.Unix(999, 0)); got != "20s" {
		t.Fatal(got)
	}
}

func TestActualWireMetadata(t *testing.T) {
	var msg snapshot
	if err := json.Unmarshal([]byte(`{"state":{"created_at":"2026-10-23T12:00:00Z","turn_started_at":"2026-10-23T12:00:10Z","turn_finished_at":null,"tokens":{"inputTokens":45,"outputTokens":10,"cachedInputTokens":20},"model":"actual","cost_usd":null},"notice":"connected"}`), &msg); err != nil {
		t.Fatal(err)
	}
	if msg.State.CreatedAt <= 0 || msg.State.TurnFinished != 0 || msg.State.Tokens.Input != 45 {
		t.Fatal(msg)
	}
}
func BenchmarkIdleViewLongTranscript(b *testing.B) {
	m := testModel()
	text := strings.Repeat("command output: passed\n", 6000)
	n, _ := m.Update(snapshot{Text: &text})
	m = n.(model)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = m.View()
	}
}
