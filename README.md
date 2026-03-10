<div align="center">

# LocalFileHub

A private, self-hosted file manager that runs on your local network. Hosted on your computer. Transfer files from your devices (Phone, Tablet, PC and so on) through a clean mobile-first web interface.
No cloud, no third-party apps, no data leaving your home.

![Python](https://img.shields.io/badge/Python-3.8+-blue?style=flat-square&logo=python)
![Flask](https://img.shields.io/badge/Flask-2.x-black?style=flat-square&logo=flask)
![SQLite](https://img.shields.io/badge/SQLite-embedded-blue?style=flat-square&logo=sqlite)
![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)

</div>

---

## ✨ Features

- **Wireless file transfer** — upload files from your phone over Wi-Fi with no cables or accounts required
- **QR code on startup** — scan from your phone to open the interface instantly
- **Folder organisation** — create folders that map to real directories on disk
- **Hashtag system** — tag files and filter by tag across your entire library
- **Grid & list views** — switch between list, 3-column and 5-column grid layouts
- **In-folder browsing** — navigate into any folder and see its contents with stats
- **Move files** — reassign files to a different folder in one tap
- **Image previews** — thumbnails and full-screen lightbox for photos
- **Search** — find files by name or tag in real time
- **Unclassified inbox** — all unassigned files collected in one place
- **Backup script** — one-click `.bat` script to back up your files and database
- **100% local** — nothing is sent outside your network

---

## 💻 Requirements

- Python 3.8+
- pip

---

## 📥 Installation

```bash
# 1. Clone the repository
git clone https://github.com/yourusername/LocalFileHub.git
cd LocalFileHub

# 2. Install dependencies
pip install flask qrcode

# 3. Start the server
python server.py
```

On startup, a QR code will appear in your terminal. Scan it with your phone (on the same Wi-Fi) to open LocalFileHub.

You can also open it manually:

- **From your phone:** `http://<YOUR_LOCAL_IP>:5000`
- **From this PC:** `http://localhost:5000`

To find your local IP on Windows, run `ipconfig` and look for _IPv4 Address_.

---

## 📁 Project structure

```
LocalFileHub/
├── server.py          # Flask backend + REST API
├── database.db        # SQLite database (auto-created on first run)
├── backup.bat         # Windows backup utility
├── uploads/           # Stored files (auto-created)
│   ├── FolderName/    # One subdirectory per folder
│   └── ...
└── index.html     # Mobile-first single-page frontend
```

---

## 🌐 API reference

| Method | Endpoint                   | Description                                  |
| ------ | -------------------------- | -------------------------------------------- |
| GET    | `/api/folders`             | List all folders                             |
| POST   | `/api/folders`             | Create a folder                              |
| PUT    | `/api/folders/<id>`        | Rename a folder                              |
| DELETE | `/api/folders/<id>`        | Delete a folder                              |
| GET    | `/api/folders/<id>/stats`  | File count and disk size for a folder        |
| GET    | `/api/files`               | List files (params: `q`, `folder_id`, `tag`) |
| POST   | `/api/files/upload`        | Upload a file                                |
| PUT    | `/api/files/<id>`          | Update name, folder, or tags                 |
| DELETE | `/api/files/<id>`          | Delete a file                                |
| GET    | `/api/files/<id>/download` | Download a file                              |
| GET    | `/api/files/<id>/preview`  | Serve file inline (for previews)             |
| GET    | `/api/tags`                | List all tags with usage count               |

---

## 💾 Backup

Run `backup.bat` (Windows) to create a timestamped backup of your `uploads/` folder and `database.db`. The script keeps the 10 most recent backups and removes older ones automatically.

> Stop the server before running a backup to avoid database conflicts.

---

## 🔐 Privacy

LocalFileHub is designed for home network use. All files stay on your machine — there is no external API, no telemetry, and no authentication required (acceptable for a trusted home network). If you need to expose the server beyond your local network, consider adding HTTPS and password protection.

---

## 🛡️ Tech stack

- **Backend:** Python + Flask
- **Database:** SQLite (via Python's built-in `sqlite3`)
- **Frontend:** Vanilla HTML, CSS, JavaScript — no build step, no frameworks
- **Fonts:** Syne + DM Mono (Google Fonts)

---

## 📜 License

This project is licensed under the **Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)** license.

### You are free to:

- ✔️ **Share** — copy and redistribute the material in any medium or format
- ✔️ **Adapt** — remix, transform, and build upon the material

### Under the following terms:

- **Attribution** — You must give appropriate credit to the author, provide a link to the license, and indicate if changes were made
- **NonCommercial** — You may not use the material for commercial purposes

### Restrictions:

- ❌ **Commercial use is strictly prohibited** without explicit permission
- ❌ No enterprise deployment or integration into paid products/services

Full license text available at: https://creativecommons.org/licenses/by-nc/4.0/

See the [`LICENSE`](LICENSE) file for full details.

---

## 👤 Author

**Carlos García**  
IT Support | Junior SOC Analyst

### Commercial Usage

If you are interested in **commercial usage or integration**, please contact me to discuss a separate licensing agreement.

---

<div align="center">

**Made with ❤️ as a technical portfolio piece**

⭐ Star this repository if you found it helpful!

© 2026 Carlos García

</div>
