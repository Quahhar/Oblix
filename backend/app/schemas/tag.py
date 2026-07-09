from pydantic import BaseModel, Field


class TagCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=128)


class TagResponse(BaseModel):
    id: str
    user_id: str
    name: str
    created_at: str

    model_config = {"from_attributes": True}