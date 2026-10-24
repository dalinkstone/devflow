// devflow-tui is a local renderer. All remote operations go through the
// self-contained CLI's durable Python bridge, never through a second API client.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"

	"charm.land/bubbles/v2/textinput"
	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

var version = "dev"

type option struct{ Label, Description string }
type question struct {
	ID          string   `json:"id"`
	Question    string   `json:"question"`
	Options     []option `json:"options"`
	MultiSelect bool     `json:"multiSelect"`
}
type interaction struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}
type tokens struct{ Input, Output, Cached int64 }

type timestamp float64

func (t *timestamp) UnmarshalJSON(data []byte) error {
	if string(data) == "null" {
		*t = 0
		return nil
	}
	var raw string
	if json.Unmarshal(data, &raw) == nil {
		v, err := time.Parse(time.RFC3339, raw)
		if err != nil {
			return err
		}
		*t = timestamp(v.Unix())
		return nil
	}
	var value float64
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	*t = timestamp(value)
	return nil
}

func (t *tokens) UnmarshalJSON(data []byte) error {
	var v struct {
		Input  int64 `json:"inputTokens"`
		Output int64 `json:"outputTokens"`
		Cached int64 `json:"cachedInputTokens"`
	}
	if err := json.Unmarshal(data, &v); err != nil {
		return err
	}
	t.Input, t.Output, t.Cached = v.Input, v.Output, v.Cached
	return nil
}

type state struct {
	ID, Title, Provider, Status, Repo, Branch, Model, Effort, Activity, PR, Error string
	CreatedAt                                                                     timestamp              `json:"created_at"`
	TurnStarted                                                                   timestamp              `json:"turn_started_at"`
	TurnFinished                                                                  timestamp              `json:"turn_finished_at"`
	Cost                                                                          *float64               `json:"cost_usd"`
	CostScope                                                                     string                 `json:"cost_scope"`
	Tokens                                                                        *tokens                `json:"tokens"`
	TokenScope                                                                    string                 `json:"token_scope"`
	ContextTokens                                                                 int64                  `json:"context_tokens"`
	ContextWindow                                                                 int64                  `json:"context_window"`
	Pending                                                                       map[string]interaction `json:"pending"`
	Queued                                                                        []json.RawMessage      `json:"queued"`
}
type snapshot struct {
	State  *state  `json:"state"`
	Text   *string `json:"text"`
	Notice string  `json:"notice"`
	Ack    *int    `json:"ack"`
	Error  string  `json:"error"`
}
type tick time.Time
type bridgeError struct{ err error }
type wizard struct {
	id        string
	questions []question
	index     int
	approval  bool
	answers   map[string]any
}
type model struct {
	width, height                   int
	state                           state
	input                           textinput.Model
	log, detail                     viewport.Model
	transcript, notice, localNotice string
	answer                          *wizard
	clock                           time.Time
	send                            func(map[string]any) tea.Cmd
	serial                          int
	saving                          map[int]bool
	detaching                       bool
}

func safe(s string) string {
	return strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' || !unicode.IsControl(r) {
			return r
		}
		return -1
	}, ansi.Strip(s))
}
func one(s string) string { return strings.Join(strings.Fields(safe(s)), " ") }
func fallback(s, alt string) string {
	if s == "" {
		return alt
	}
	return one(s)
}
func clockCmd() tea.Cmd { return tea.Tick(time.Second, func(t time.Time) tea.Msg { return tick(t) }) }
func newModel(send func(map[string]any) tea.Cmd) model {
	i := textinput.New()
	i.Prompt = "> "
	i.Placeholder = "Ask the agent, or /help"
	i.CharLimit = 32000
	i.SetVirtualCursor(false)
	i.SetStyles(textinput.Styles{Focused: textinput.StyleState{Prompt: lipgloss.NewStyle().Bold(true)}})
	i.Focus()
	v := viewport.New(viewport.WithWidth(80), viewport.WithHeight(12))
	v.SoftWrap = false // Wrap only on transcript/width changes, not every clock tick.
	d := viewport.New(viewport.WithWidth(80), viewport.WithHeight(12))
	d.SoftWrap = true
	return model{input: i, log: v, detail: d, width: 80, height: 24, clock: time.Now(),
		send: send, notice: "connecting…", saving: map[int]bool{}}
}
func (m model) Init() tea.Cmd { return clockCmd() }
func (m *model) submit(req map[string]any) tea.Cmd {
	m.serial++
	req["local_id"] = m.serial
	m.saving[m.serial] = true
	return m.send(req)
}
func (m *model) openQuestion() {
	ids := make([]string, 0, len(m.state.Pending))
	for id := range m.state.Pending {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	if len(ids) == 0 {
		return
	}
	r := m.state.Pending[ids[0]]
	var p struct {
		Questions []question `json:"questions"`
	}
	_ = json.Unmarshal(r.Params, &p)
	approval := len(p.Questions) == 0
	if approval {
		var detail bytes.Buffer
		if json.Indent(&detail, r.Params, "", "  ") != nil {
			detail.Write(r.Params)
		}
		p.Questions = []question{{ID: "approval", Question: "Allow " + r.Method + "?\n" + detail.String(),
			Options: []option{{Label: "Deny"}, {Label: "Approve once"}}}}
	}
	m.answer = &wizard{id: ids[0], questions: p.Questions, approval: approval, answers: map[string]any{}}
	m.input.Reset()
	m.showQuestion()
}

// showQuestion only rebuilds the detail viewport when the active question changes.
func (m *model) showQuestion() {
	q := m.answer.questions[m.answer.index]
	lines := []string{fmt.Sprintf("Input %d/%d  [%s]", m.answer.index+1, len(m.answer.questions), m.answer.id), "", safe(q.Question), ""}
	for i, o := range q.Options {
		lines = append(lines, fmt.Sprintf("%d. %s  %s", i+1, one(o.Label), one(o.Description)))
	}
	lines = append(lines, "", "Type a number or your own answer. Comma-separated numbers for multi-select.", "Esc leaves this pending. No default approval.")
	m.detail.SetContent(strings.Join(lines, "\n"))
	m.detail.GotoTop()
}
func (m *model) reply() (tea.Cmd, error) {
	a := m.answer
	q := a.questions[a.index]
	value := strings.TrimSpace(m.input.Value())
	if value == "" {
		return nil, errors.New("enter an answer, or Esc to leave pending")
	}
	parts := strings.Split(value, ",")
	selected := []string{}
	for _, p := range parts {
		n, err := strconv.Atoi(strings.TrimSpace(p))
		if err != nil || n < 1 || n > len(q.Options) {
			selected = nil
			break
		}
		selected = append(selected, q.Options[n-1].Label)
	}
	var answer any = value
	if len(selected) > 0 {
		if q.MultiSelect {
			answer = selected
		} else if len(selected) == 1 {
			answer = selected[0]
		} else {
			return nil, errors.New("select one option")
		}
	}
	reply := map[string]any{}
	if a.approval {
		if answer != "Deny" && answer != "Approve once" {
			return nil, errors.New("enter 1 to deny or 2 to approve once")
		}
		reply["allow"] = answer == "Approve once"
	} else {
		id := q.ID
		if id == "" {
			id = q.Question
		}
		a.answers[id] = answer
		a.index++
		if a.index < len(a.questions) {
			m.input.Reset()
			m.showQuestion()
			return nil, nil
		}
		reply["answers"] = a.answers
	}
	cmd := m.submit(map[string]any{"op": "answer", "interaction": a.id, "reply": reply})
	m.answer = nil
	m.input.Reset()
	return cmd, nil
}
func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		bottom := m.log.AtBottom()
		m.log.SetWidth(max(1, m.width))
		m.log.SetContent(ansi.Hardwrap(m.transcript, max(1, m.width), true))
		m.detail.SetWidth(max(1, m.width))
		m.log.SetHeight(max(1, m.height-10))
		m.detail.SetHeight(max(1, m.height-10))
		m.input.SetWidth(max(1, m.width-3))
		if bottom {
			m.log.GotoBottom()
		}
	case tick:
		m.clock = time.Time(msg)
		return m, clockCmd()
	case snapshot:
		if msg.Ack != nil {
			delete(m.saving, *msg.Ack)
		}
		if msg.Error != "" {
			m.localNotice = safe(msg.Error)
			m.detaching = false
		}
		if msg.State != nil {
			m.state = *msg.State
			m.notice = safe(msg.Notice)
			if m.answer != nil {
				if _, ok := m.state.Pending[m.answer.id]; !ok {
					m.answer = nil
					m.input.Reset()
					m.localNotice = "Request is no longer pending"
				}
			}
		}
		if msg.Text != nil {
			bottom := m.log.AtBottom()
			m.transcript = safe(*msg.Text)
			// Defensive bound even if a future bridge sends an oversized transcript.
			r := []rune(m.transcript)
			if len(r) > 150000 {
				m.transcript = string(r[len(r)-150000:])
			}
			m.log.SetContent(ansi.Hardwrap(m.transcript, max(1, m.width), true))
			if bottom {
				m.log.GotoBottom()
			}
		}
		if m.detaching && len(m.saving) == 0 {
			return m, tea.Quit
		}
	case bridgeError:
		m.localNotice = "Local bridge stopped: " + safe(msg.err.Error()) + ". Ctrl-D to detach; remote work continues."
		m.notice = ""
		m.saving = map[int]bool{}
	case tea.KeyPressMsg:
		switch msg.String() {
		case "ctrl+d":
			if len(m.saving) > 0 {
				m.detaching = true
				m.localNotice = "Saving input before detaching…"
				return m, nil
			}
			return m, tea.Quit
		case "ctrl+c":
			m.localNotice = "Interrupt requested"
			return m, m.submit(map[string]any{"op": "command", "text": "/interrupt"})
		case "tab":
			if m.answer == nil {
				m.openQuestion()
			}
			return m, nil
		case "esc":
			m.answer = nil
			m.input.Reset()
			return m, nil
		case "pgup":
			if m.answer != nil {
				m.detail.PageUp()
			} else {
				m.log.PageUp()
			}
			return m, nil
		case "pgdown":
			if m.answer != nil {
				m.detail.PageDown()
			} else {
				m.log.PageDown()
			}
			return m, nil
		case "ctrl+end":
			m.log.GotoBottom()
			return m, nil
		case "enter", "ctrl+j":
			if m.answer != nil {
				cmd, err := m.reply()
				if err != nil {
					m.localNotice = err.Error()
				}
				return m, cmd
			}
			line := strings.TrimSpace(m.input.Value())
			if line == "/detach" {
				m.input.Reset()
				return m.Update(tea.KeyPressMsg{Code: 'd', Mod: tea.ModCtrl})
			}
			if line == "/help" {
				m.localNotice = "/interrupt · /recover · /pr TITLE · /approve ID · /deny ID · /answer ID JSON · /detach"
				m.input.Reset()
				return m, nil
			}
			if line != "" {
				m.input.Reset()
				m.localNotice = "Saved prompts continue remotely after detach"
				return m, m.submit(map[string]any{"op": "command", "text": line})
			}
		}
	}
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}
func elapsed(start, finish timestamp, now time.Time) string {
	if start <= 0 {
		return "not started"
	}
	end := timestamp(now.Unix())
	if finish > 0 {
		end = finish
	}
	d := time.Duration(max(0, end-start)) * time.Second
	return d.String()
}
func (m model) View() tea.View {
	if m.width < 35 || m.height < 14 {
		v := tea.NewView("Resize terminal to at least 35×14. Ctrl-D detaches.")
		v.AltScreen = true
		return v
	}
	s := m.state
	title := fallback(s.Title, fallback(s.ID, "devflow"))
	if s.Title != "" && s.ID != "" {
		title += " [" + one(s.ID) + "]"
	}
	metrics := "spend: not reported"
	if s.Cost != nil {
		metrics = fmt.Sprintf("spend: ~$%.4f (%s)", *s.Cost, fallback(s.CostScope, "provider estimate"))
	}
	if s.Tokens != nil {
		metrics += fmt.Sprintf("  tokens: %d in / %d out / %d cached (%s)", s.Tokens.Input, s.Tokens.Output, s.Tokens.Cached, one(s.TokenScope))
	}
	activity := fallback(s.Activity, s.Status)
	if len(s.Pending) > 0 {
		activity = fmt.Sprintf("%d input needed · Tab to review", len(s.Pending))
	}
	if s.ContextWindow > 0 {
		activity += fmt.Sprintf("  context: %d/%d", s.ContextTokens, s.ContextWindow)
	}
	activity += fmt.Sprintf("  queued: %d", len(s.Queued))
	heading := lipgloss.NewStyle().Bold(true)
	row := func(s string) string { return ansi.Truncate(one(s), m.width, "…") }
	note := m.localNotice
	if s.Error != "" {
		note = s.Error
	}
	if m.notice != "" && !strings.HasPrefix(m.notice, "connected") {
		note = m.notice
	}
	if len(m.saving) > 0 {
		note = fmt.Sprintf("Saving %d local input(s)…  %s", len(m.saving), note)
	}
	if note == "" {
		note = "Remote compute stays on after detach. Spend excludes Daytona; estimates are not invoices."
	}
	body := m.log.View()
	if m.answer != nil {
		body = m.detail.View()
	}
	controls := "Enter send · Tab input · PgUp/PgDn history · Ctrl-C interrupt · Ctrl-D detach"
	if m.answer != nil {
		controls = "Enter answer · Esc leave pending · PgUp/PgDn full details · Ctrl-D detach"
	}
	lines := []string{
		heading.Render(row(title + "  ·  " + fallback(s.Status, "connecting"))),
		row(fallback(s.Provider, "provider unknown") + "  model: " + fallback(s.Model, "not reported") + "  effort: " + fallback(s.Effort, "default (not reported)")),
		row(metrics),
		row("turn: " + elapsed(s.TurnStarted, s.TurnFinished, m.clock) + "  session age: " + elapsed(s.CreatedAt, 0, m.clock)),
		row(s.Repo + "  " + s.Branch + "  " + s.PR),
		row(activity),
		strings.Repeat("─", m.width), body,
		row(controls), row(note), m.input.View(),
	}
	v := tea.NewView(strings.Join(lines, "\n"))
	v.AltScreen = true
	v.Cursor = m.input.Cursor()
	if v.Cursor != nil {
		v.Cursor.Y = m.height - 1
	}
	return v
}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Println("devflow-tui " + version)
		return
	}
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "devflow-tui is launched by dv attach; build with make tui")
		os.Exit(2)
	}
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run(args []string) error {
	child := exec.Command(args[0], args[1:]...)
	child.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	out, err := child.StdoutPipe()
	if err != nil {
		return err
	}
	in, err := child.StdinPipe()
	if err != nil {
		return err
	}
	// Keep Python diagnostics off the active terminal; bridge errors are explicit.
	child.Stderr = io.Discard
	if err = child.Start(); err != nil {
		return err
	}
	defer func() { _ = in.Close(); _ = syscall.Kill(-child.Process.Pid, syscall.SIGTERM); _ = child.Wait() }()
	outgoing := make(chan map[string]any, 64)
	done := make(chan struct{})
	defer close(done)
	send := func(value map[string]any) tea.Cmd {
		// Enqueue synchronously in key-event order; pipe writes never block Update.
		select {
		case outgoing <- value:
			return nil
		default:
			return func() tea.Msg { return bridgeError{errors.New("input backlog full; last input was not saved")} }
		}
	}
	p := tea.NewProgram(newModel(send))
	go func() {
		encoder := json.NewEncoder(in)
		for {
			select {
			case value := <-outgoing:
				if err := encoder.Encode(value); err != nil {
					p.Send(bridgeError{err})
					return
				}
			case <-done:
				return
			}
		}
	}()
	go func() {
		scanner := bufio.NewScanner(out)
		scanner.Buffer(make([]byte, 65536), 8*1024*1024)
		for scanner.Scan() {
			var msg snapshot
			if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
				p.Send(bridgeError{fmt.Errorf("invalid bridge message: %w", err)})
				return
			}
			p.Send(msg)
		}
		err := scanner.Err()
		if err == nil {
			err = io.EOF
		}
		p.Send(bridgeError{err})
	}()
	finished, err := p.Run()
	name := "SESSION"
	if m, ok := finished.(model); ok && m.state.ID != "" {
		name = one(m.state.ID)
	}
	fmt.Println("Detached. Remote work continues. Reattach: dv attach " + name)
	return err
}
