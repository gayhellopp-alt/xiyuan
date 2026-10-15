"""Read logs written by either Windows PowerShell 5 or PowerShell 7."""
def read_text(path):
    raw = path.read_bytes()
    return raw.decode('utf-16' if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8-sig')
