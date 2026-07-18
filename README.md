# myshortner02 — URL Shortener

A minimal, production-ready URL shortener built with **Python / FastAPI** backed by **PostgreSQL on AWS RDS**, deployed on **EC2** via Terraform + Ansible.

## API

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/shorten` | Create a short link |
| `GET` | `/{code}` | Redirect to original URL (301) |
| `GET` | `/{code}/stats` | Hit count + metadata |
| `GET` | `/health` | Health check |

### POST /shorten

```json
{
  "url": "https://www.example.com/some/very/long/path",
  "custom_code": "mylink"   // optional
}
```

Response `201`:
```json
{
  "code": "mylink",
  "short_url": "http://<server>/mylink",
  "original_url": "https://www.example.com/some/very/long/path"
}
```

### GET /{code}/stats

```json
{
  "code": "mylink",
  "original_url": "https://www.example.com/some/very/long/path",
  "hits": 42,
  "created_at": "2024-05-01T12:00:00"
}
```

## Local development

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Set environment variables
export DB_HOST=localhost DB_PORT=5432 DB_NAME=shortener DB_USER=shortener DB_PASSWORD=localpass BASE_URL=http://localhost:8000

uvicorn app.main:app --reload
```

Interactive docs: http://localhost:8000/docs

## Infrastructure

| Resource | Type | Notes |
|----------|------|-------|
| EC2 | t3.small | Amazon Linux 2023, runs Uvicorn behind nginx |
| RDS | db.t3.micro | PostgreSQL 15, single-AZ, private subnet |
| Security Groups | — | EC2 open on 80/22; RDS open only to EC2 SG on 5432 |
| Elastic IP | — | Static public IP for EC2 |

## CI/CD

Pushes to `main` trigger: **lint → provision → configure → verify**

- **provision**: Terraform creates/updates EC2 + RDS
- **configure**: Ansible deploys app code, writes `.env`, restarts services
- **verify**: `curl` health check with retries
