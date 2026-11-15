#!/bin/sh
# Deckhand pairing: connect the Deckhand app to this server by scanning a QR code.
#
# Run it as the user the app should log in as (over SSH from a laptop, or in your provider's web console):
#   curl -fsSL https://raw.githubusercontent.com/Riyad-Eita/deckhand/main/scripts/pair.sh | sh
#
# What it does, and nothing else:
#   1. Makes a one-time SSH key and adds it to ~/.ssh/authorized_keys, locked down: it can't open a shell, forward
#      ports or run anything except handing over one public key, and it expires after 15 minutes.
#   2. Shows a QR code with this server's address, your user name, the server's host key fingerprints and that
#      one-time key. Scan it with the iPhone camera or in Deckhand.
#   3. The app makes its own key on the iPhone and hands over the public half. The one-time key removes itself.
#
# Options (environment): PAIR_HOST / PAIR_PORT (the address the iPhone should use), PAIR_NAME, PAIR_MINUTES.
set -eu
umask 077

say() { printf '%s\n' "$*"; }
command -v ssh-keygen >/dev/null 2>&1 || { say "ssh-keygen is missing (package openssh-client)."; exit 1; }
command -v python3 >/dev/null 2>&1 || { say "python3 is missing. Install it (apt install python3) and run this again."; exit 1; }

D="$HOME/.deckhand/pair"
AK="$HOME/.ssh/authorized_keys"
mkdir -p "$D" "$HOME/.ssh"
chmod 700 "$HOME/.deckhand" "$D" "$HOME/.ssh"
touch "$AK"
chmod 600 "$AK"

# The forced command of the one-time key: takes one public key, then removes the one-time key.
cat > "$D/accept.sh" <<'ACCEPT'
#!/bin/sh
# Deckhand pairing: the only thing a one-time pairing key may do. Adds the public key the app sends
# (in SSH_ORIGINAL_COMMAND) to authorized_keys once, then removes the pairing key. Managed by Deckhand.
id="$1"; D="$HOME/.deckhand/pair"; AK="$HOME/.ssh/authorized_keys"
case "$id" in *[!0-9a-f]*|"") echo "@@bad"; exit 1 ;; esac
drop() {
  grep -v " deckhand-pair-$id\$" "$AK" > "$AK.dh" 2>/dev/null
  cat "$AK.dh" > "$AK"; rm -f "$AK.dh" "$D/$id" "$D/$id.pub" "$D/$id.until"
}
until=$(cat "$D/$id.until" 2>/dev/null || echo 0)
if [ "$(date +%s)" -gt "$until" ]; then drop; echo "@@expired"; exit 1; fi
key=${SSH_ORIGINAL_COMMAND:-}
if ! printf '%s\n' "$key" | grep -Eq '^(ssh-ed25519|ecdsa-sha2-nistp256) [A-Za-z0-9+/]{40,255}={0,2} [A-Za-z0-9 ._@()-]{1,60}$'; then
  echo "@@badkey"; exit 1
fi
grep -qxF -- "$key" "$AK" || printf '%s\n' "$key" >> "$AK"
drop
echo "@@paired"
ACCEPT
chmod 700 "$D/accept.sh"

# Earlier codes that were never used.
now=$(date +%s)
for f in "$D"/*.until; do
  [ -f "$f" ] || continue
  old=$(basename "$f" .until)
  if [ "$(cat "$f")" -lt "$now" ]; then
    grep -v " deckhand-pair-$old\$" "$AK" > "$AK.dh" 2>/dev/null || true
    cat "$AK.dh" > "$AK"; rm -f "$AK.dh" "$D/$old" "$D/$old.pub" "$f"
  fi
done

ID=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
MIN=${PAIR_MINUTES:-15}
UNTIL=$((now + MIN * 60))
ssh-keygen -q -t ed25519 -N '' -C "deckhand-pair-$ID" -f "$D/$ID"
echo "$UNTIL" > "$D/$ID.until"

# OpenSSH 8.2+ also expires the key itself.
OPTS="restrict,command=\"/bin/sh $D/accept.sh $ID\""
v=$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
if [ -n "$v" ] && [ "$(echo "$v" | awk '{print ($1 > 8 || ($1 == 8 && $2 >= 2)) ? 1 : 0}')" = 1 ]; then
  EXP=$(date -d "@$UNTIL" +%Y%m%d%H%M 2>/dev/null || date -r "$UNTIL" +%Y%m%d%H%M)
  OPTS="$OPTS,expiry-time=\"$EXP\""
fi
printf '%s %s\n' "$OPTS" "$(cat "$D/$ID.pub")" >> "$AK"

# Where the iPhone should connect: what this SSH session used, else the first address.
set -- ${SSH_CONNECTION:-}
HOST=${PAIR_HOST:-${3:-}}
PORT=${PAIR_PORT:-${4:-}}
[ -n "$HOST" ] || HOST=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "$HOST" ] || HOST=$(hostname)
if [ -z "$PORT" ]; then
  PORT=$(awk 'tolower($1) == "port" {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
  PORT=${PORT:-22}
fi
NAME=${PAIR_NAME:-$(hostname -s 2>/dev/null || hostname)}
FPS=$(for k in /etc/ssh/ssh_host_*_key.pub; do [ -r "$k" ] && ssh-keygen -lf "$k" -E sha256 2>/dev/null | awk '{print $2}'; done | sed 's/^SHA256://' | tr '\n' ',' | sed 's/,$//')

python3 - "$D/$ID" "$HOST" "$PORT" "$(id -un)" "$NAME" "$FPS" "$UNTIL" "$MIN" <<'PY'
import base64, os, sys, urllib.parse

# A minimal QR code encoder (byte mode, error correction L, versions 1-15), so nothing needs to be installed.
TABLE = {1: (7, [(1, 19)]), 2: (10, [(1, 34)]), 3: (15, [(1, 55)]), 4: (20, [(1, 80)]), 5: (26, [(1, 108)]),
         6: (18, [(2, 68)]), 7: (20, [(2, 78)]), 8: (24, [(2, 97)]), 9: (30, [(2, 116)]), 10: (18, [(2, 68), (2, 69)]),
         11: (20, [(4, 81)]), 12: (24, [(2, 92), (2, 93)]), 13: (26, [(4, 107)]), 14: (30, [(3, 115), (1, 116)]),
         15: (22, [(5, 87), (1, 88)])}
ALIGN = {1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34], 7: [6, 22, 38], 8: [6, 24, 42],
         9: [6, 26, 46], 10: [6, 28, 50], 11: [6, 30, 54], 12: [6, 32, 58], 13: [6, 34, 62], 14: [6, 26, 46, 66],
         15: [6, 26, 48, 70]}
REMAINDER = {1: 0, 2: 7, 3: 7, 4: 7, 5: 7, 6: 7, 7: 0, 8: 0, 9: 0, 10: 0, 11: 0, 12: 0, 13: 0, 14: 3, 15: 3}

EXP, LOG = [0] * 512, [0] * 256
x = 1
for i in range(255):
    EXP[i], LOG[x] = x, i
    x <<= 1
    if x & 0x100:
        x ^= 0x11D
for i in range(255, 512):
    EXP[i] = EXP[i - 255]


def mul(a, b):
    return 0 if a == 0 or b == 0 else EXP[LOG[a] + LOG[b]]


def ec_words(block, n):
    gen = [1]
    for i in range(n):
        nxt = [0] * (len(gen) + 1)
        for j, g in enumerate(gen):
            nxt[j] ^= g
            nxt[j + 1] ^= mul(g, EXP[i])
        gen = nxt
    res = list(block) + [0] * n
    for i in range(len(block)):
        c = res[i]
        if c:
            for j in range(1, len(gen)):
                res[i + j] ^= mul(gen[j], c)
    return res[len(block):]


def encode(data):
    for ver in range(1, 16):
        ec, groups = TABLE[ver]
        cap = sum(n * d for n, d in groups)
        count = 8 if ver < 10 else 16
        if 4 + count + 8 * len(data) <= cap * 8:
            break
    else:
        raise ValueError("too long for a QR code")
    bits = []

    def put(v, n):
        bits.extend((v >> i) & 1 for i in range(n - 1, -1, -1))
    put(4, 4)
    put(len(data), count)
    for b in data:
        put(b, 8)
    put(0, min(4, cap * 8 - len(bits)))
    while len(bits) % 8:
        bits.append(0)
    words = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pad = 0
    while len(words) < cap:
        words.append((0xEC, 0x11)[pad % 2])
        pad += 1
    blocks, k = [], 0
    for n, d in groups:
        for _ in range(n):
            blocks.append(words[k:k + d])
            k += d
    ecs = [ec_words(b, ec) for b in blocks]
    final = []
    for i in range(max(len(b) for b in blocks)):
        final += [b[i] for b in blocks if i < len(b)]
    for i in range(ec):
        final += [e[i] for e in ecs]
    stream = [(w >> i) & 1 for w in final for i in range(7, -1, -1)] + [0] * REMAINDER[ver]

    size = 17 + 4 * ver
    m = [[False] * size for _ in range(size)]
    f = [[False] * size for _ in range(size)]

    def setf(r, c, v):
        m[r][c], f[r][c] = v, True
    for r0, c0 in ((0, 0), (0, size - 7), (size - 7, 0)):
        for i in range(-1, 8):
            for j in range(-1, 8):
                r, c = r0 + i, c0 + j
                if 0 <= r < size and 0 <= c < size:
                    setf(r, c, 0 <= i <= 6 and 0 <= j <= 6 and (i in (0, 6) or j in (0, 6) or (2 <= i <= 4 and 2 <= j <= 4)))
    for i in range(size):
        if not f[6][i]:
            setf(6, i, i % 2 == 0)
        if not f[i][6]:
            setf(i, 6, i % 2 == 0)
    pos = ALIGN[ver]
    for r in pos:
        for c in pos:
            if (r, c) in ((6, 6), (6, pos[-1]), (pos[-1], 6)):
                continue
            for i in range(-2, 3):
                for j in range(-2, 3):
                    setf(r + i, c + j, max(abs(i), abs(j)) != 1)
    # Reserve the format and version areas (drawn after masking).
    for i in range(9):
        if not f[8][i]:
            setf(8, i, False)
        if not f[i][8]:
            setf(i, 8, False)
    for i in range(8):
        setf(8, size - 1 - i, False)
        setf(size - 1 - i, 8, False)
    if ver >= 7:
        rem = ver
        for _ in range(12):
            rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
        vbits = ver << 12 | rem
        for i in range(18):
            bit = (vbits >> i) & 1 == 1
            a, b = size - 11 + i % 3, i // 3
            setf(b, a, bit)
            setf(a, b, bit)
    i = 0
    right = size - 1
    while right >= 1:
        if right == 6:
            right = 5
        upward = ((right + 1) & 2) == 0
        for vert in range(size):
            r = size - 1 - vert if upward else vert
            for j in range(2):
                c = right - j
                if not f[r][c]:
                    m[r][c] = i < len(stream) and stream[i] == 1
                    i += 1
        right -= 2

    masks = [lambda r, c: (r + c) % 2 == 0, lambda r, c: r % 2 == 0, lambda r, c: c % 3 == 0,
             lambda r, c: (r + c) % 3 == 0, lambda r, c: (r // 2 + c // 3) % 2 == 0,
             lambda r, c: (r * c) % 2 + (r * c) % 3 == 0, lambda r, c: ((r * c) % 2 + (r * c) % 3) % 2 == 0,
             lambda r, c: ((r + c) % 2 + (r * c) % 3) % 2 == 0]

    def with_mask(k):
        g = [row[:] for row in m]
        for r in range(size):
            for c in range(size):
                if not f[r][c] and masks[k](r, c):
                    g[r][c] = not g[r][c]
        data = (1 << 3) | k  # error correction L
        rem = data
        for _ in range(10):
            rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        fb = (data << 10 | rem) ^ 0x5412
        bit = lambda n: (fb >> n) & 1 == 1
        for n in range(6):
            g[n][8] = bit(n)
        g[7][8], g[8][8], g[8][7] = bit(6), bit(7), bit(8)
        for n in range(9, 15):
            g[8][14 - n] = bit(n)
        for n in range(8):
            g[8][size - 1 - n] = bit(n)
        for n in range(8, 15):
            g[size - 15 + n][8] = bit(n)
        g[size - 8][8] = True
        return g

    def penalty(g):
        p = 0
        lines = g + [list(col) for col in zip(*g)]
        for line in lines:
            run, prev = 0, None
            for v in line:
                run = run + 1 if v == prev else 1
                prev = v
                if run == 5:
                    p += 3
                elif run > 5:
                    p += 1
            s = "".join("1" if v else "0" for v in line)
            p += 40 * (s.count("10111010000") + s.count("00001011101"))
        for r in range(size - 1):
            for c in range(size - 1):
                if g[r][c] == g[r][c + 1] == g[r + 1][c] == g[r + 1][c + 1]:
                    p += 3
        dark = sum(v for row in g for v in row)
        p += 10 * (abs(dark * 20 - size * size * 10) // (size * size))
        return p
    return min((with_mask(k) for k in range(8)), key=penalty)


def show(g):
    q = 2
    w = len(g) + 2 * q
    rows = [[False] * w for _ in range(q)] + [[False] * q + r + [False] * q for r in g] + [[False] * w for _ in range(q)]
    if len(rows) % 2:
        rows.append([False] * w)
    for y in range(0, len(rows), 2):
        line = "".join("█" if t and b else "▀" if t else "▄" if b else " " for t, b in zip(rows[y], rows[y + 1]))
        sys.stdout.write("\033[30;47m" + line + "\033[0m\n")


if sys.argv[1] == "--matrix":  # tests: the modules as 0/1 rows
    for row in encode(sys.argv[2].encode()):
        print("".join("1" if v else "0" for v in row))
    sys.exit(0)

keyfile, host, port, user, name, fps, until, minutes = sys.argv[1:9]
# The one-time key's 32-byte seed from the OpenSSH private key file.
body = "".join(open(keyfile).read().split("-----")[2].split())
blob = base64.b64decode(body)
assert blob.startswith(b"openssh-key-v1\0")


def string(b, i):
    n = int.from_bytes(b[i:i + 4], "big")
    return b[i + 4:i + 4 + n], i + 4 + n
i = 15
for _ in range(3):
    _, i = string(blob, i)
i += 4
_, i = string(blob, i)
private, _ = string(blob, i)
j = 8
for _ in range(2):
    _, j = string(private, j)
secret, _ = string(private, j)
seed = base64.urlsafe_b64encode(secret[:32]).decode().rstrip("=")
q = urllib.parse.urlencode({"h": host, "p": port, "u": user, "n": name, "k": seed, "f": fps, "e": until})
link = "deckhand://pair?" + q
if os.environ.get("PAIR_PRINT_LINK") == "1":  # tests
    print("@@link " + link)
print()
show(encode(link.encode()))
print()
print("  Scan this with the iPhone camera, or in Deckhand: Add Server → Scan a Pairing Code.")
print("  The app connects to %s@%s port %s and puts its own key on this server." % (user, host, port))
print("  The code works once and for %s minutes. Don't share it: until then it lets someone add a key." % minutes)
print("  Wrong address? Run it again with PAIR_HOST=… (and PAIR_PORT=…) in front of sh.")
print()
PY
