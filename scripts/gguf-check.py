import struct, sys, io

T = ['u8','i8','u16','i16','u32','i32','f32','bool','str','arr','u64','i64','f64']

def rd(f, n):
    b = f.read(n)
    if len(b) != n: raise EOFError('truncated in header')
    return b

def rstr(f):
    (n,) = struct.unpack('<Q', rd(f, 8)); return rd(f, n).decode('utf-8', 'replace')

def rval(f, t):
    t = T[t]
    if t == 'u8':  return struct.unpack('<B', rd(f,1))[0]
    if t == 'i8':  return struct.unpack('<b', rd(f,1))[0]
    if t == 'u16': return struct.unpack('<H', rd(f,2))[0]
    if t == 'i16': return struct.unpack('<h', rd(f,2))[0]
    if t == 'u32': return struct.unpack('<I', rd(f,4))[0]
    if t == 'i32': return struct.unpack('<i', rd(f,4))[0]
    if t == 'f32': return struct.unpack('<f', rd(f,4))[0]
    if t == 'bool':return struct.unpack('<?', rd(f,1))[0]
    if t == 'str': return rstr(f)
    if t == 'u64': return struct.unpack('<Q', rd(f,8))[0]
    if t == 'i64': return struct.unpack('<q', rd(f,8))[0]
    if t == 'f64': return struct.unpack('<d', rd(f,8))[0]
    if t == 'arr':
        (et,) = struct.unpack('<I', rd(f,4)); (n,) = struct.unpack('<Q', rd(f,8))
        return [rval(f, et) for _ in range(n)]
    raise ValueError('type %d' % t)

path = sys.argv[1]
f = open(path, 'rb')
import os
fsize = os.path.getsize(path)
assert f.read(4) == b'GGUF', 'not a GGUF'
(ver,) = struct.unpack('<I', rd(f,4))
(nt, nkv) = struct.unpack('<QQ', rd(f,16))
md = {}
for _ in range(nkv):
    k = rstr(f); (t,) = struct.unpack('<I', rd(f,4)); md[k] = rval(f, t)
arch = md.get('general.architecture', '?')
align = md.get('general.alignment', 32)
maxoff = 0; dims_seen = set(); qtypes = {}
for _ in range(nt):
    nm = rstr(f); (nd,) = struct.unpack('<I', rd(f,4))
    dims = [struct.unpack('<Q', rd(f,8))[0] for _ in range(nd)]
    (dt,) = struct.unpack('<I', rd(f,4)); (off,) = struct.unpack('<Q', rd(f,8))
    maxoff = max(maxoff, off); dims_seen.add(tuple(dims))
    qtypes[dt] = qtypes.get(dt, 0) + 1
data_start = (f.tell() + align - 1) // align * align
print('file            : %.2f GB   GGUF v%d   %d tensors, %d metadata keys' % (fsize/2**30, ver, nt, len(md)))
print('architecture    : %s  n_layers=%s  n_ctx_train=%s' % (arch, md.get(arch+'.block_count'), md.get(arch+'.context_length_train')))
print('tensor data at  : %.1f MB  (first tensor must start at/after this)' % (data_start/2**20))
print('largest tensor  : offset %.2f GB  -> needs file >= %.2f GB' % (maxoff/2**30, (data_start+maxoff)/2**30))
print('tail room       : %.2f GB of tensor data past the last offset (must be > 0)' % ((fsize-data_start-maxoff)/2**30))
ok = fsize > data_start + maxoff
print('truncation      : %s' % ('OK - file is large enough to hold every tensor' if ok else 'TRUNCATED - file ends before the last tensor'))
ct = md.get('tokenizer.chat_template') or ''
print('chat template   : %s (%d chars)' % ('present' if ct else 'MISSING - chat requests will fall back to plain prompt', len(ct)))
print('eos/bos/pad ids : %s / %s / %s' % (md.get('tokenizer.ggml.eos_token_id'), md.get('tokenizer.ggml.bos_token_id'), md.get('tokenizer.ggml.padding_token_id')))
print('vocab / type    : %s tokens, %s' % (md.get('tokenizer.ggml.tokens') and len(md['tokenizer.ggml.tokens']), md.get('tokenizer.ggml.model')))
print('kv cache hints  : head_dim=%s  n_head=%s  n_head_kv=%s' % (md.get(arch+'.attention.length_k'), md.get(arch+'.attention.head_count'), md.get(arch+'.attention.head_count_kv')))
print('mtp / predict   : %s' % [k for k in md if 'mtp' in k.lower() or 'predict' in k.lower()][:6])
print('quant types     : %s' % sorted(qtypes.items(), key=lambda x: -x[1])[:6])
sys.exit(0 if ok else 1)
