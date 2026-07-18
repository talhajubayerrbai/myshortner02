import os


class Settings:
    db_host: str = os.environ.get("DB_HOST", "localhost")
    db_port: int = int(os.environ.get("DB_PORT", "5432"))
    db_name: str = os.environ.get("DB_NAME", "shortener")
    db_user: str = os.environ.get("DB_USER", "shortener")
    db_password: str = os.environ.get("DB_PASSWORD", "")
    base_url: str = os.environ.get("BASE_URL", "http://localhost:8000")

    @property
    def database_url(self) -> str:
        return (
            f"postgresql+psycopg2://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )


settings = Settings()
