from pathlib import Path
from typing import Literal

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="OUTDOOR_", env_file=".env", extra="ignore"
    )
    client_token: SecretStr = SecretStr("")
    database_path: Path = Path("data/outdoor.sqlite3")
    provider_mode: Literal["disabled", "mock", "openrouter"] = "disabled"
    openrouter_api_key: SecretStr = SecretStr("")
    openrouter_vision_model: str = Field(default="", max_length=200)
    openrouter_timeout_seconds: float = Field(default=45, gt=0, le=180, allow_inf_nan=False)
    max_upload_bytes: int = Field(default=5 * 1024 * 1024, gt=0)
    max_request_bytes: int = Field(default=5 * 1024 * 1024 + 65536, gt=0)
    max_image_pixels: int = Field(default=20_000_000, gt=0)
    image_max_dimension: int = Field(default=1600, gt=0)
    image_jpeg_quality: int = Field(default=80, ge=1, le=95)

    @model_validator(mode="after")
    def check_limits(self):
        if self.max_request_bytes <= self.max_upload_bytes:
            raise ValueError("max_request_bytes must exceed max_upload_bytes")
        return self
