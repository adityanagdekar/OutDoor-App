# OutDoor — Anti-Doomscrolling App

A native iOS app that encourages outdoor walking instead of habitual Instagram scrolling. Verified walking earns usage allowance, while Shortcuts automations and reminders help manage scrolling habits.

> 🚧 **Work in Progress:** OutDoor is under active development. Features, APIs, and setup instructions may change.

## Features

- Background walking tracking using Core Location and Core Motion.
- Verified walking time, estimated distance, and a current-location map.
- Outdoor photography challenges with in-app camera capture.
- Walking credits converted into Instagram allowance.
- Shortcuts App Intents for estimated Instagram session accounting.
- Notifications when allowance expires.
- Insights comparing walking time, estimated Instagram usage, and excess usage.

Excess usage is recorded for analytics—it never reduces future walking credits.

## Tech Stack

- **iOS:** Swift, SwiftUI, MapKit, AVFoundation, App Intents
- **Backend:** Python, FastAPI, Pydantic, SQLite
- **Planned AI integration:** Gemma through OpenRouter
- **Deployment target:** DigitalOcean Droplet

## Architecture

```text
iPhone → FastAPI → OpenRouter/Gemma
             ↕
           SQLite
```

Walking and Instagram accounting remain on-device. The backend assigns challenges and will verify submitted photos.

## Project Structure

```text
OutDoor/
├── OutDoor.xcodeproj/
├── OutDoor/             # iOS application
└── OutDoor_Backend/     # FastAPI backend and tests
```

## Backend Setup

Requires Python 3.11+.

```bash
cd OutDoor_Backend
python3 -m venv .venv
source .venv/bin/activate
pip install -e '.[test]'
cp .env.example .env
```

Configure `OUTDOOR_CLIENT_TOKEN` in `.env`. Set `OUTDOOR_PROVIDER_MODE=mock` for explicitly simulated responses.

```bash
uvicorn app.main:app --reload
```

## API

| Method | Endpoint |
| ------ | -------- |
| GET | `/health` |
| GET | `/api/v1/topics` |
| POST | `/api/v1/challenges/generate` |
| GET | `/api/v1/challenges/{id}` |
| POST | `/api/v1/challenges/{id}/regenerate` |
| POST | `/api/v1/challenges/{id}/verify` |

Functional endpoints require bearer authentication. POST operations require an `Idempotency-Key`. Current photo uploads support JPEG/PNG up to **5 MiB**.

## Status and Limitations

Walking, local allowance accounting, notifications, and the backend foundation are implemented. Image processing, live Gemma integration, iOS/backend integration, and deployment remain pending.

Instagram usage is **estimated through Shortcuts**. OutDoor redirects app openings and provides reminders; it cannot forcibly end an active Instagram session.
