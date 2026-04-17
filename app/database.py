import os
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import sessionmaker, DeclarativeBase

DATABASE_URL = os.getenv('DATABASE_URL', '').replace('postgresql://', 'postgresql+asyncpg://')

engine = create_async_engine(DATABASE_URL, echo=False) if DATABASE_URL else None
AsyncSessionLocal = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False) if engine else None

class Base(DeclarativeBase):
    pass

async def connect_db():
    if engine is None:
        print('PostgreSQL not configured — skipping connection')
        return
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    print('PostgreSQL connected')

async def disconnect_db():
    if engine is None:
        return
    await engine.dispose()