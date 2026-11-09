from __future__ import annotations

import pytest
from support import Env, build_env


@pytest.fixture
def env(tmp_path) -> Env:
    return build_env(tmp_path / "data")
