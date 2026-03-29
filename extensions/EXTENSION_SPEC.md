# LocalFileHub — Extension Developer Specification

> **Target audience:** AI agents and experienced developers building extensions.
> **Constraint:** Do NOT modify core files. Read this spec, ship a working extension.

---

## 1. Architecture Overview

```
LocalFileHub/
├── server.py              # Core Flask app, hook registry, frontend injection (READ-ONLY)
├── load_extensions.py     # Auto-discovery loader (READ-ONLY)
├── index.html             # Base frontend — single-page app (READ-ONLY)
├── Launch.py              # GUI launcher wrapper (READ-ONLY)
├── database.db            # SQLite (WAL mode, FK enabled)
├── uploads/               # File storage root (subfolders per folder entity)
└── extensions/
    ├── __init__.py        # Re-exports shared utilities (do not modify)
    ├── shared.py          # Shared utilities across extensions (see §9)
    └── <ext_name>/
        ├── __init__.py    # REQUIRED: must expose register(app)
        └── ...            # Any additional files or subdirectories
```

**Boot order:**

```
_bootstrap() [at server.py import time]
    └── load_extensions(app)   → imports extensions.shared, then calls register(app) on every extension
    └── init_db()              → creates core tables, then fires on_db_init hooks
Flask starts (threaded=True, port 5000)
```

Extensions are loaded **before** `init_db()`, so `on_db_init` hooks are registered
in time for the DB init phase to fire them.

---

## 2. Discovery & Registration

**Auto-discovery rules (`load_extensions.py`):**

- Must be a directory under `extensions/`
- Must contain `__init__.py`
- Must expose `register(app: Flask) -> None`
- Directories starting with `_` or `.` are skipped
- Loaded alphabetically by directory name

**Registration pattern:**

```python
# extensions/myext/__init__.py
def register(app):
    from flask import jsonify, request
    from server import register_hook, get_db, register_frontend_extension

    # 1. Register lifecycle hooks
    register_hook('on_db_init', _on_db_init)
    register_hook('on_image_uploaded', _on_image_uploaded)

    # 2. Add API routes
    @app.route('/api/myext/data')
    def myext_data():
        ...

    # 3. Register frontend UI fragment (optional)
    register_frontend_extension({...})
```

**Failure behaviour:** Exception in `register()` → extension skipped, traceback printed,
server continues. All other extensions are unaffected.

**`server` module aliasing:** `_bootstrap()` calls
`sys.modules.setdefault('server', sys.modules[__name__])` before loading extensions,
so extensions doing `from server import ...` always get the single real module
regardless of launch mode.

---

## 3. Import Rules

### Server symbols — always import lazily

Import `server` symbols **inside functions**, never at module top level, to avoid
circular import issues:

```python
# ✅ Correct — lazy import inside function body
def _on_image_uploaded(file_id, save_path, tags_raw, conn):
    from server import get_db, file_disk_path, IMAGE_MIMETYPES
    ...

# ✅ Correct — lazy import inside register()
def register(app):
    from server import register_hook, get_db, register_frontend_extension
    ...

# ❌ Wrong — top-level import causes circular import
from server import get_db
```

### `extensions.shared` — safe at module level

`shared.py` is pre-loaded before any extension runs, so it is safe to import
at module level:

```python
from extensions.shared import score_as_handle, is_person_tag
```

### Multi-file extensions — submodule import exception

For larger extensions that split logic across multiple files, submodules may
import `server` at their own module top level, **provided those submodules are
only imported from inside `register()`**, not at the extension's package top level.
This means `server` is already fully initialised by the time those imports execute.

```python
# extensions/myext/helpers.py
from server import get_db          # ✅ safe — only imported from inside register()

# extensions/myext/__init__.py
def register(app):
    from .helpers import do_something   # ✅ deferred: server is ready at this point
    ...
```

```python
# extensions/myext/__init__.py
from .helpers import do_something   # ❌ wrong — runs at load time, before server is ready
```

---

## 4. Hook System

### Registration

```python
from server import register_hook

register_hook('on_db_init',        my_db_init_fn)
register_hook('on_image_uploaded', my_upload_fn)
```

All hook registrations **must happen inside `register(app)`**, not at module level.

### Available Hooks

#### `on_db_init(conn: sqlite3.Connection)`

Fired inside `init_db()` after all core tables are created. Use it to CREATE extension
tables or ALTER existing ones.

**Rules:**

- Use `conn.execute()` per statement — never `conn.executescript()` (causes implicit COMMIT)
- Do NOT call `conn.commit()` — the caller commits after all hooks run
- Do NOT call `conn.close()`
- Safe to use `ALTER TABLE ADD COLUMN` with existence checks via `PRAGMA table_info`

```python
def _on_db_init(conn):
    conn.execute('''
        CREATE TABLE IF NOT EXISTS myext_items (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id INTEGER REFERENCES files(id) ON DELETE CASCADE,
            data    TEXT,
            created TEXT DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    # Safe column migration
    cols = {r[1] for r in conn.execute("PRAGMA table_info(myext_items)").fetchall()}
    if 'extra_col' not in cols:
        conn.execute("ALTER TABLE myext_items ADD COLUMN extra_col TEXT")
```

#### `on_image_uploaded(file_id: int, save_path: str, tags_raw: str, conn: sqlite3.Connection)`

Fired in `upload_file()` **after** the file row is committed. Only fires for image
mimetypes (`IMAGE_MIMETYPES` set in `server.py`).

**Parameters:**

- `file_id` — the new row's PK in `files`
- `save_path` — absolute path to the saved file on disk
- `tags_raw` — raw comma-separated tag string from the upload form (unparsed)
- `conn` — an open, already-committed read connection

**Rules:**

- ✅ Read freely from the provided `conn`
- ✅ Open a **new** `get_db()` connection for any writes
- ❌ Do NOT write through the provided `conn` (already committed)
- ❌ Do NOT block — runs synchronously in the request thread
- ✅ Spawn a daemon thread for heavy work (encoding, network calls, etc.)

```python
def _on_image_uploaded(file_id, save_path, tags_raw, conn):
    import threading
    from server import get_db
    def _worker(fid, path):
        own_conn = get_db()
        try:
            own_conn.execute(
                'INSERT INTO myext_items (file_id, data) VALUES (?, ?)',
                (fid, 'processed')
            )
            own_conn.commit()
        finally:
            own_conn.close()
    threading.Thread(target=_worker, args=(file_id, save_path), daemon=True).start()
```

---

## 5. Database API

```python
from server import get_db

conn = get_db()
rows = conn.execute('SELECT ...', params).fetchall()
conn.commit()   # if you wrote anything
conn.close()
```

`get_db()` returns a connection configured with:

- `row_factory = sqlite3.Row` (access columns by name: `row['id']`)
- `PRAGMA foreign_keys = ON`
- `PRAGMA journal_mode = WAL`
- `PRAGMA synchronous = NORMAL`
- `PRAGMA cache_size = -8000`
- `PRAGMA temp_store = MEMORY`
- `PRAGMA mmap_size = 134217728`

**Thread safety:** Flask runs `threaded=True`. Open a new `get_db()` per request/thread;
never share connections across threads.

### Core Schema (read-only reference)

```sql
files(
    id            INTEGER PK,
    filename      TEXT,          -- stored UUID-like name on disk
    original_name TEXT,          -- original upload name
    folder_id     INTEGER,       -- FK → folders(id) ON DELETE SET NULL
    size          INTEGER,       -- bytes
    mimetype      TEXT,
    uploaded_at   TEXT,
    sha256        TEXT,          -- exact duplicate detection
    phash         TEXT,          -- perceptual hash (imagehash, may be NULL)
)

folders(id, name, created_at)

tags(id, name UNIQUE)

file_tags(file_id, tag_id)      -- M2M; both FK with ON DELETE CASCADE

rules(id, position, enabled, condition, action, created_at)
```

### Extension Table Conventions

```sql
-- Always prefix table names with your extension slug
CREATE TABLE IF NOT EXISTS myext_data (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    file_id INTEGER REFERENCES files(id) ON DELETE CASCADE,
    ...
);
```

### Server Helpers

All symbols below must be imported lazily (inside functions):

```python
from server import (
    get_db,                  # () → sqlite3.Connection (configured)
    file_disk_path,          # (stored_name, folder_name=None) → absolute path str
    folder_disk_path,        # (folder_name) → absolute dir path str
    get_thumbnail_bytes,     # (src_path, stored_name) → WebP bytes | None
    get_file_tags,           # (conn, file_id) → [tag_name, ...]
    get_tags_for_ids,        # (conn, [file_id, ...]) → {file_id: [tag_name, ...]}
    file_to_dict,            # (row, tags=None) → dict  (standard file payload, see §5.1)
    resolve_sort,            # (sort_arg, dir_arg) → (col_str, dir_str)  (see §5.2)
    compute_sha256,          # (path) → hex str
    compute_phash,           # (path) → hex str | None  (requires imagehash)
    PIL_AVAILABLE,           # bool
    IMAGEHASH_AVAILABLE,     # bool
    IMAGE_MIMETYPES,         # frozenset of image mimetype strings
    VIDEO_MIMETYPES,         # frozenset of video mimetype strings
    UPLOAD_FOLDER,           # absolute path to uploads/
    BASE_DIR,                # absolute path to project root
)
```

### 5.1 `file_to_dict` — Standard File Payload

`file_to_dict(row, tags=None)` converts a `sqlite3.Row` from the `files` table into
a plain `dict` with the following fields. This is the canonical representation used
by the SPA and all API responses:

```python
{
    'id':            int,
    'filename':      str,   # stored name on disk (UUID-like)
    'original_name': str,
    'folder_id':     int | None,
    'size':          int,   # bytes
    'mimetype':      str,
    'uploaded_at':   str,   # ISO timestamp
    'sha256':        str | None,
    'phash':         str | None,
    'tags':          list[str],  # tag names; [] if tags=None
}
```

The `f` object available in `card_actions` template strings (§7) exposes exactly
these fields.

### 5.2 `resolve_sort` — Sorting Helper

Validates and normalises `sort`/`dir` query-string arguments to a safe SQL pair:

```python
sort_col, sort_dir = resolve_sort(
    request.args.get('sort'),   # e.g. 'uploaded_at', 'original_name', 'size'
    request.args.get('dir'),    # 'asc' | 'desc'
)
# sort_col → validated column name (defaults to 'uploaded_at')
# sort_dir → 'ASC' | 'DESC'   (defaults to 'DESC')
```

Use this in extension routes that expose their own paginated file lists to match
the sorting behaviour of the core `/api/files` endpoint.

---

## 6. HTTP Routes

### Extension Routes

Register routes inside `register(app)`. You are not limited to `/api/` paths —
extensions can also serve standalone HTML pages or proxy routes at any path,
as long as they do not conflict with the core routes listed below.

```python
def register(app):
    # Standard API route
    @app.route('/api/myext/items', methods=['GET'])
    def myext_list():
        conn = get_db()
        rows = conn.execute('SELECT * FROM myext_items ORDER BY created DESC').fetchall()
        conn.close()
        return jsonify([dict(r) for r in rows])

    # Standalone HTML page (outside the SPA)
    @app.route('/myext-panel')
    def myext_panel():
        from flask import send_from_directory
        return send_from_directory(_UI_DIR, 'panel.html')
```

**Namespace rule:** Prefix API routes with `/api/<extname>/` to avoid collisions
with core routes and other extensions.

### Flask Request Lifecycle Hooks

Extensions may register `before_request` handlers via the standard Flask API.
Use `flask.g` to store per-request state (e.g. authenticated user):

```python
def register(app):
    from flask import g, request, jsonify, abort

    def _before_request():
        g.user = _resolve_user_from_request(request)
        # Return a Response to short-circuit the request; return None to continue.

    app.before_request(_before_request)
```

`g` is the Flask application context global — it is fresh for each request and
safe to read from any route or hook running in the same request cycle.

### Core API Routes (already registered — do not redeclare)

| Method | Path                         | Description                                                                      |
| ------ | ---------------------------- | -------------------------------------------------------------------------------- |
| GET    | `/api/files`                 | List files (supports `q`, `folder_id`, `tag`, `sort`, `dir`, `limit`, `offset`) |
| POST   | `/api/files/upload`          | Upload a file (multipart: `file`, `folder_id`, `tags`)                           |
| GET    | `/api/files/<id>`            | Single file metadata                                                             |
| PUT    | `/api/files/<id>`            | Update file (`folder_id`, `tags`, `original_name`)                               |
| DELETE | `/api/files/<id>`            | Delete file                                                                      |
| PUT    | `/api/files/batch`           | Batch update (`ids`, `folder_id`, `add_tags`, `remove_tags`)                     |
| DELETE | `/api/files/batch`           | Batch delete (`ids`)                                                             |
| GET    | `/api/files/<id>/preview`    | Serve thumbnail (WebP) or original; `?full=1` bypasses thumb                     |
| GET    | `/api/files/<id>/download`   | Download original with `Content-Disposition: attachment`                         |
| GET    | `/api/folders`               | List folders                                                                     |
| POST   | `/api/folders`               | Create folder                                                                     |
| PUT    | `/api/folders/<id>`          | Rename folder                                                                    |
| DELETE | `/api/folders/<id>`          | Delete folder                                                                    |
| GET    | `/api/folders/<id>/stats`    | `{total, size}` for a folder                                                     |
| GET    | `/api/folders/<id>/download` | Download folder as ZIP                                                           |
| GET    | `/api/tags`                  | All tags with usage counts                                                       |
| GET    | `/api/duplicates`            | Duplicate groups (`?type=exact\|similar`)                                        |
| GET    | `/api/extensions/frontend`   | List of registered frontend extension configs                                    |
| GET    | `/api/thumbnails/cache-info` | LRU cache stats                                                                  |
| DELETE | `/api/thumbnails/cache`      | Flush thumbnail cache                                                            |

---

## 7. Frontend Extension System

The SPA (`index.html`) calls `GET /api/extensions/frontend` at startup and dynamically
injects each registered extension's UI fragments. Extensions declare their UI by
calling `register_frontend_extension(config)` inside `register(app)`.

### Registration

```python
from server import register_frontend_extension

register_frontend_extension({
    'id':             'myext',           # REQUIRED — unique slug; used as page id
    'tab_icon':       '🔧',             # emoji/text for the tab button
    'tab_label':      'My Extension',   # human-readable tab label
    'page_html':      '...',            # inner HTML for <div class="page" id="page-myext">
    'overlay_html':   '...',            # (optional) HTML injected before </body>
    'card_actions':   '...',            # (optional) HTML injected in every image card's .file-actions
    'edit_modal_btn': '...',            # (optional) HTML appended inside the Edit-file modal
    'css':            '...',            # CSS rules injected into <head> (no <style> wrapper)
    'js':             '...',            # JS injected at end of <body> (no <script> tags)
})
```

**`id` is always required.** If both `tab_icon` and `tab_label` are empty strings,
no tab is created — useful for extensions that only inject overlays, card buttons,
or edit-modal buttons.

### Config Fields Reference

| Key              | Type | Required | Description                                                                          |
| ---------------- | ---- | -------- | ------------------------------------------------------------------------------------ |
| `id`             | str  | ✅       | Unique slug. Becomes the DOM id `page-{id}` and the `switchTab()` argument.         |
| `tab_icon`       | str  | —        | Emoji or text shown in the tab button.                                               |
| `tab_label`      | str  | —        | Human-readable label.                                                                |
| `page_html`      | str  | —        | Complete inner HTML for the extension's page `<div>`.                                |
| `overlay_html`   | str  | —        | Modals, lightboxes, or any top-level HTML injected before `</body>`.                 |
| `card_actions`   | str  | —        | HTML injected into every image file-card's `.file-actions` div. Supports template literals evaluated by the SPA (see §7.1). |
| `edit_modal_btn` | str  | —        | HTML appended inside the edit-file modal after the Save button.                      |
| `css`            | str  | —        | Raw CSS (no wrapper tag).                                                            |
| `js`             | str  | —        | Raw JavaScript (no wrapper tag).                                                     |

### 7.1 `card_actions` Template Literals

The SPA evaluates the `card_actions` string as a JavaScript template literal, with
the current file object bound as `f`. All fields from `file_to_dict` (§5.1) are
available:

```javascript
// Available template variables inside card_actions:
${f.id}             // int   — file PK
${f.filename}       // str   — stored name on disk
${f.original_name}  // str   — display name
${f.folder_id}      // int | null
${f.size}           // int   — bytes
${f.mimetype}       // str
${f.uploaded_at}    // str   — ISO timestamp
${f.sha256}         // str | null
${f.phash}          // str | null
${f.tags}           // array of tag name strings
```

Example — a button that is only shown when the file has tags:

```python
_CARD_ACTIONS = (
    "${f.tags && f.tags.length ? "
    "`<button onclick=\"myextOpen(${f.id})\">🔍</button>`"
    " : ''}"
)
```

### Frontend Constraints

- Use relative URLs (`/api/myext/...`) — never hardcode `localhost:5000`
- Do not assume base `index.html` DOM structure beyond the documented injection points
- Do not inject `<script>` or `<style>` tags — the SPA wraps `js` and `css` fields itself
- The SPA exposes `switchTab(id)` globally; your JS can call it to navigate to any tab

### CSS Custom Properties

The SPA defines CSS custom properties that extensions should reuse for visual consistency:

```css
var(--bg)       /* main background */
var(--bg2)      /* secondary background / card surface */
var(--text)     /* primary text */
var(--text2)    /* secondary / muted text */
var(--text3)    /* tertiary / disabled text */
var(--accent)   /* primary accent colour */
var(--border)   /* standard border colour */
```

---

## 8. Static Files

```python
import os
from flask import send_from_directory

_EXT_DIR = os.path.dirname(os.path.abspath(__file__))

def register(app):
    @app.route('/ext/myext/<path:filename>')
    def myext_static(filename):
        return send_from_directory(os.path.join(_EXT_DIR, 'static'), filename)
```

Reference from frontend: `<img src="/ext/myext/logo.png">`

---

## 9. Shared Utilities (`extensions/shared.py`)

`shared.py` is the place for utilities that multiple extensions need. It is
pre-loaded by `load_extensions.py` before any extension runs, making it safe
to import at module level:

```python
# Safe at module level
from extensions.shared import my_shared_utility
```

**Contract: `shared.py` must remain dependency-free.** No Flask, no `server`
imports, no third-party packages. It must be importable before the Flask app
is fully initialised.

If you are adding a new extension that needs a utility that another extension
already implements, move it to `shared.py` instead of duplicating it. Any
symbol added to `shared.py` becomes part of the shared API surface — document
it with a docstring and keep it generic enough to be reusable.

---

## 10. Minimal Valid Extension

```python
# extensions/myext/__init__.py

def _on_db_init(conn):
    conn.execute('''
        CREATE TABLE IF NOT EXISTS myext_log (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id   INTEGER REFERENCES files(id) ON DELETE CASCADE,
            logged_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
    ''')


def _on_image_uploaded(file_id, save_path, tags_raw, conn):
    import threading
    from server import get_db
    def _worker(fid):
        own = get_db()
        try:
            own.execute('INSERT INTO myext_log (file_id) VALUES (?)', (fid,))
            own.commit()
        finally:
            own.close()
    threading.Thread(target=_worker, args=(file_id,), daemon=True).start()


def register(app):
    from flask import jsonify
    from server import register_hook, get_db

    register_hook('on_db_init', _on_db_init)
    register_hook('on_image_uploaded', _on_image_uploaded)

    @app.route('/api/myext/log')
    def myext_log():
        conn = get_db()
        rows = conn.execute(
            'SELECT ml.*, f.original_name '
            'FROM myext_log ml JOIN files f ON f.id = ml.file_id '
            'ORDER BY ml.logged_at DESC LIMIT 50'
        ).fetchall()
        conn.close()
        return jsonify([dict(r) for r in rows])
```

---

## 11. Extension with Frontend Tab

```python
# extensions/myext/__init__.py

_PAGE_HTML = '''
<div style="padding:1rem">
  <h2>My Extension</h2>
  <div id="myext-content">Loading...</div>
</div>
'''

_JS = '''
async function myextLoad() {
  const res = await fetch('/api/myext/log');
  const data = await res.json();
  document.getElementById('myext-content').textContent = JSON.stringify(data);
}
document.addEventListener('DOMContentLoaded', myextLoad);
'''

_CSS = '''
#page-myext { background: var(--bg); color: var(--text); }
'''


def _on_db_init(conn):
    conn.execute('''
        CREATE TABLE IF NOT EXISTS myext_log (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id   INTEGER REFERENCES files(id) ON DELETE CASCADE,
            logged_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
    ''')


def register(app):
    from flask import jsonify
    from server import register_hook, get_db, register_frontend_extension

    register_hook('on_db_init', _on_db_init)

    @app.route('/api/myext/log')
    def myext_log():
        conn = get_db()
        rows = conn.execute('SELECT * FROM myext_log ORDER BY logged_at DESC LIMIT 50').fetchall()
        conn.close()
        return jsonify([dict(r) for r in rows])

    register_frontend_extension({
        'id':        'myext',
        'tab_icon':  '🔧',
        'tab_label': 'MyExt',
        'page_html': _PAGE_HTML,
        'css':       _CSS,
        'js':        _JS,
    })
```

---

## 12. Multi-File Extension Layout

For extensions that grow beyond a single file, split logic into submodules.
The only rule is that those submodules must only be imported from **inside**
`register()`, never at the package's top level:

```
extensions/myext/
├── __init__.py        # register(app) entry point — minimal glue
├── core.py            # business logic, helpers, hooks
├── routes/
│   ├── __init__.py    # (can be empty)
│   ├── api.py         # main API routes
│   └── admin.py       # admin-only routes
└── ui/
    ├── panel.html     # standalone HTML page (if needed)
    └── ...
```

```python
# extensions/myext/__init__.py
import os
_UI_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ui')

def register(app):
    # All submodule imports happen here — server is ready at this point
    from server import register_hook, register_frontend_extension
    from .core import db_init_hook, before_request_hook
    from .routes.api   import register_api_routes
    from .routes.admin import register_admin_routes

    register_hook('on_db_init', db_init_hook)
    app.before_request(before_request_hook)
    register_api_routes(app)
    register_admin_routes(app)

    # Standalone page outside the SPA
    from flask import send_from_directory
    @app.route('/myext-panel')
    def myext_panel():
        return send_from_directory(_UI_DIR, 'panel.html')
```

```python
# extensions/myext/core.py
# Submodules imported from inside register() may import server at module level
from server import get_db

def db_init_hook(conn):
    ...

def before_request_hook():
    from flask import g, request
    g.user = _resolve_user(request)
```

```python
# extensions/myext/routes/api.py
from flask import jsonify, request, g
from server import get_db

def register_api_routes(app):
    @app.route('/api/myext/items')
    def myext_items():
        conn = get_db()
        rows = conn.execute('SELECT * FROM myext_items').fetchall()
        conn.close()
        return jsonify([dict(r) for r in rows])
```

---

## 13. Environment & Constraints

| Constraint             | Detail                                                   |
| ---------------------- | -------------------------------------------------------- |
| Python                 | 3.8+                                                     |
| Flask                  | 3.0+                                                     |
| SQLite                 | WAL mode, FK enforced — always use `ON DELETE CASCADE`   |
| Threading              | `threaded=True`; one `get_db()` per thread, never shared |
| Max upload             | 500 MB per file                                          |
| File paths             | Always `os.path.join()` — never hardcode separators      |
| Side effects at import | None — all setup must be inside `register()`             |
| Inter-extension comms  | Not supported directly — use DB as shared state          |
| Optional deps          | Wrap in `try/except ImportError`; degrade gracefully     |

### Optional Dependencies Available in the Runtime Environment

```python
# PIL / Pillow (thumbnails, image processing)
from server import PIL_AVAILABLE        # check before use

# imagehash (perceptual hashing)
from server import IMAGEHASH_AVAILABLE

# flask_limiter (rate limiting — may fall back to built-in)
# No server flag; guard directly:
try:
    from flask_limiter import Limiter
    LIMITER_AVAILABLE = True
except ImportError:
    LIMITER_AVAILABLE = False
```

---

## 14. Anti-Patterns

| ❌ Don't                                                   | ✅ Do instead                                                          |
| ---------------------------------------------------------- | ---------------------------------------------------------------------- |
| `import server; server._hooks = ...`                       | Use `register_hook()`                                                  |
| Modify `server.py`, `index.html`, `load_extensions.py`     | Add routes/hooks in `register()`                                       |
| `conn.executescript(...)` in `on_db_init`                  | `conn.execute(...)` per statement                                      |
| Write via the `conn` provided in `on_image_uploaded`       | Open a new `get_db()` connection                                       |
| Block in hooks (network, heavy compute)                    | Spawn a daemon thread                                                  |
| Generic table names (`data`, `log`, `users`)               | Prefix: `myext_data`, `myext_log`                                      |
| `from server import ...` at extension package top level    | Import lazily inside functions or inside `register()`                  |
| `from .submodule import ...` at extension package top level| Import submodules inside `register()` only                             |
| `conn.close()` inside `on_db_init`                         | Never close the provided conn                                          |
| Hardcode `localhost:5000` in frontend                      | Use relative URLs (`/api/...`)                                         |
| Share a `get_db()` connection across threads               | One connection per thread/request                                      |
| `<style>` or `<script>` tags in `css`/`js` config fields  | Raw CSS/JS only — the SPA wraps them                                   |
| Hardcode CSS colours in frontend                           | Use `var(--bg)`, `var(--text)`, `var(--accent)`, etc.                  |
| Duplicate logic that belongs in `shared.py`                | Add it to `shared.py` and import from there                            |

---

## 15. Checklist

```
□ extensions/<name>/__init__.py exists
□ register(app) is the sole entry point — no side effects at module level
□ Hook registrations are inside register(), not at module top
□ server symbols imported lazily (inside functions or inside register())
□ Submodules only imported from inside register() — never at package top level
□ Extension DB tables prefixed with extension slug
□ API routes prefixed with /api/<extname>/
□ on_db_init uses conn.execute() only — no executescript(), no commit(), no close()
□ on_image_uploaded opens its own get_db() for any writes
□ Blocking operations in hooks run in daemon threads
□ register_frontend_extension called with 'id' field present
□ css/js config fields contain raw code — no wrapper tags
□ card_actions template uses only documented f.* fields
□ Frontend uses relative URLs and var(--*) CSS custom properties
□ Optional dependencies wrapped in try/except ImportError
□ No modifications to core files
```
