from datetime import datetime

from sqlalchemy import Column, DateTime, Integer, String

from app.database import Base


class ShortLink(Base):
    __tablename__ = "short_links"

    id = Column(Integer, primary_key=True, index=True)
    code = Column(String(16), unique=True, index=True, nullable=False)
    original_url = Column(String(2048), nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    hits = Column(Integer, default=0, nullable=False)
