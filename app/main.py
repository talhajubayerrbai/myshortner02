from fastapi import Depends, FastAPI, HTTPException
from fastapi.responses import RedirectResponse
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.config import settings
from app.database import Base, engine, get_db
from app.models import ShortLink
from app.schemas import LinkStats, ShortenRequest, ShortenResponse
from app.shortener import generate_code

# Create tables on startup (Alembic handles migrations in production)
Base.metadata.create_all(bind=engine)

app = FastAPI(title="URL Shortener", version="1.0.0")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/shorten", response_model=ShortenResponse, status_code=201)
def shorten_url(payload: ShortenRequest, db: Session = Depends(get_db)):
    code = payload.custom_code or generate_code()

    # Retry on collision for auto-generated codes
    for _ in range(5):
        link = ShortLink(code=code, original_url=str(payload.url))
        db.add(link)
        try:
            db.commit()
            db.refresh(link)
            return ShortenResponse(
                code=link.code,
                short_url=f"{settings.base_url}/{link.code}",
                original_url=link.original_url,
            )
        except IntegrityError:
            db.rollback()
            if payload.custom_code:
                raise HTTPException(status_code=409, detail="Custom code already taken")
            code = generate_code()

    raise HTTPException(status_code=500, detail="Could not generate a unique code")


@app.get("/{code}/stats", response_model=LinkStats)
def link_stats(code: str, db: Session = Depends(get_db)):
    link = db.query(ShortLink).filter(ShortLink.code == code).first()
    if not link:
        raise HTTPException(status_code=404, detail="Short link not found")
    return LinkStats(
        code=link.code,
        original_url=link.original_url,
        hits=link.hits,
        created_at=link.created_at.isoformat(),
    )


@app.get("/{code}")
def redirect(code: str, db: Session = Depends(get_db)):
    link = db.query(ShortLink).filter(ShortLink.code == code).first()
    if not link:
        raise HTTPException(status_code=404, detail="Short link not found")
    link.hits += 1
    db.commit()
    return RedirectResponse(url=link.original_url, status_code=301)
