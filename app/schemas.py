from pydantic import BaseModel, HttpUrl


class ShortenRequest(BaseModel):
    url: HttpUrl
    custom_code: str | None = None


class ShortenResponse(BaseModel):
    code: str
    short_url: str
    original_url: str

    model_config = {"from_attributes": True}


class LinkStats(BaseModel):
    code: str
    original_url: str
    hits: int
    created_at: str

    model_config = {"from_attributes": True}
