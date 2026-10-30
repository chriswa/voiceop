#!/usr/bin/env python3
"""End to end: the handsfree plugin (a mod) in a real interactive Claude Code.

Starts `claude` (haiku) in a pty with the plugin from this checkout, runs
/handsfree, then plays the user through Voice Operator's
`/v1/voice-mode/simulate` (as if hands-free had heard it): a turn woken by
speech, ten turns in a row, and "turn hands-free voice chat off", which the
agent must act on with its `mcp__handsfree__stop` tool. Prints OK/TIMEOUT per step.

Needs the running Voice Operator to have voice mode (API 18). Every reply is
spoken aloud, and attaching takes hands-free from Spaceterm. It will not start
while hands-free is attached to another Claude Code session (yours), and it
stops if one takes it mid-run: its simulated words are only ever for its own
session.

    python3 scripts/voice-mode-e2e.py [workdir]
"""
import os, pty, time, uuid, glob, select, re, json, sys, tempfile, urllib.request, urllib.parse
SID = str(uuid.uuid4())
WORK = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="voice-mode-e2e-")
PLUGIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "claude-plugin", "handsfree")
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "ANTHROPIC")) and k not in {"CLAUDECODE", "AI_AGENT"}}
env["TERM"] = "xterm-256color"
_port = json.load(open(os.path.expanduser("~/Library/Application Support/VoiceOperator/speech-service.json")))["port"]
_now = json.load(urllib.request.urlopen(f"http://127.0.0.1:{_port}/v1/voice-mode"))
if _now.get("attached"):
    sys.exit(f"hands-free is attached to another session ({_now.get('project')}); turn it off there first")
pid, fd = pty.fork()
if pid == 0:
    os.chdir(WORK)
    os.execvpe("claude", ["claude", "--session-id", SID, "--model", "haiku", "--plugin-dir", PLUGIN], env)
    os._exit(1)
buf = b""
ANSI = re.compile(rb'\x1b\[[0-9;?]*[a-zA-Z]|\x1b[\]P][^\x07\x1b]*(\x07|\x1b\\)?')
screen = lambda: ANSI.sub(b'', buf).decode('utf8', 'replace')
def pump(d):
    global buf
    end = time.time() + d
    while time.time() < end:
        if select.select([fd], [], [], 0.2)[0]:
            try: buf += os.read(fd, 65536)
            except OSError: return
def port():
    return json.load(open(os.path.expanduser("~/Library/Application Support/VoiceOperator/speech-service.json")))["port"]
def status():
    return json.load(urllib.request.urlopen(f"http://127.0.0.1:{port()}/v1/voice-mode"))
def simulate(text):
    if not attached():
        sys.exit("STOPPED: another session took hands-free mid-run; not simulating into it")
    data = urllib.parse.urlencode({"text": text, "session_id": SID}).encode()
    try: print("simulate:", urllib.request.urlopen(f"http://127.0.0.1:{port()}/v1/voice-mode/simulate", data).read())
    except Exception as e: print("simulate failed", e)
def transcript():
    g = glob.glob(os.path.expanduser("~/.claude/projects/*/%s.jsonl" % SID))
    return open(g[0]).read() if g else ""
def assistant_texts():
    out = []
    for l in transcript().splitlines():
        try: o = json.loads(l)
        except: continue
        if o.get("type") == "assistant":
            for b in o["message"].get("content", []):
                if isinstance(b, dict) and b.get("type") == "text": out.append(b["text"])
                if isinstance(b, dict) and b.get("type") == "tool_use": out.append("TOOL:" + json.dumps(b.get("input"))[:200])
    return out
def wait_for(pred, secs, label):
    for i in range(int(secs / 2)):
        pump(2)
        if pred(): print(f"OK {label} after {i*2}s"); return True
    print(f"TIMEOUT {label}"); return False
def attached():
    try: return json.load(open(os.path.expanduser("~/Library/Application Support/VoiceOperator/voice-mode.json")))["session_id"] == SID
    except Exception: return False
def typ(s):
    os.write(fd, s.encode()); time.sleep(1.2); os.write(fd, b"\r")

pump(8)
if 'trust' in screen():
    os.write(fd, b"\x1b[B"); time.sleep(0.6); os.write(fd, b"\r"); pump(8)
typ("/handsfree")
wait_for(lambda: attached(), 60, "attached")
squash = lambda: screen().replace(" ", "")
wait_for(lambda: "transcribing" in squash() and ("Keeptalking" in squash() or "first" in squash()), 30, "band above the prompt")
print("ASSISTANT:", assistant_texts()[-3:])
pump(6)
n = len(assistant_texts())
simulate("Claude, reply with only the token made by joining ZEB and RAFF, no separator.")
wait_for(lambda: any("ZEBRAFF" in t for t in assistant_texts()), 90, "woken by speech")
for k in range(9):
    pump(4)
    simulate(f"Reply with only the number {k} plus {100}, as digits.")
    wait_for(lambda: any(str(100 + k) in t for t in assistant_texts()), 60, f"turn {k}")
pump(4)
simulate("Okay, turn hands-free voice chat off now please.")
wait_for(lambda: not attached(), 90, "detached by voice")
pump(5)
print("ASSISTANT tail:", assistant_texts()[-4:])
tx = transcript()
print("voice prompts:", tx.count("Reply with only the number"))
os.kill(pid, 15)
print("SID", SID)
