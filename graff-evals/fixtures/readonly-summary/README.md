# Notes

A local notebook application. Entries live in SQLite, auth is a bearer
token, and the UI module renders the list. No network services.

Architecture: `src/app.py` starts the process, `src/store.py` loads
entries, `src/auth.py` checks tokens, `src/ui.py` renders, `src/config.py`
holds the db path.
