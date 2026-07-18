# myshortner02 — Working Notes

## Project
- Python 3.12 + FastAPI + SQLAlchemy
- PostgreSQL 15 on RDS (db.t3.micro, single-AZ, private)
- EC2 t3.small, Amazon Linux 2023 (SSH user: ec2-user, pkg: dnf)
- Nginx as reverse proxy on port 80 → uvicorn on 127.0.0.1:8000
- No tests (user explicitly opted out)

## Status
- [x] Architecture written (arch rev 1)
- [x] Pipeline written (pipeline rev 1)
- [x] Plan approved
- [x] All files generated
- [ ] validate_project
- [ ] create_repo_and_push
- [ ] DB_PASSWORD secret set
- [ ] deploy

## Key decisions
- No Alembic migrations — Base.metadata.create_all() on startup (Tier 1 simplicity)
- SSH_PUBLIC_KEY passed as terraform var (platform secret) for key pair
- RDS endpoint split to strip port suffix before passing to Ansible
- nginx conf.d/shortener.conf; default.conf removed to avoid conflicts
- venv at /opt/shortener/venv, systemd ExecStart uses absolute venv path
- .env written by Ansible with mode 0600

## Secrets needed
- DB_PASSWORD — generate strong alphanumeric, set via set_pipeline_secret before deploy
- SSH_PUBLIC_KEY, SSH_PRIVATE_KEY, SSH_USER — platform-managed
- AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, TF_STATE_BUCKET, PROJECT_NAME — platform-managed

## Gotchas
- Amazon Linux 2023 uses dnf; playbook uses ansible.builtin.dnf
- python3.12 package available in AL2023 repos
- Ansible copy src path is relative to playbook dir — using ../  to copy repo root
