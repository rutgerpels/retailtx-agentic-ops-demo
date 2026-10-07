FROM python:3.11-slim-bookworm@sha256:0a310eeecf4e1f5a0743f9a6520c90c88d089c903ca5fd283f501e3a805f5f89 AS runtime
ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
ARG PIP_INDEX_URL=https://pypi.org/simple
RUN useradd --uid 10001 --create-home workload
WORKDIR /work
COPY pyproject.toml requirements-dev.lock ./
RUN pip install --no-cache-dir --require-hashes -r requirements-dev.lock
COPY app ./app
RUN pip install --no-cache-dir --no-deps --no-build-isolation .
COPY sim ./sim
COPY chaos ./chaos
USER workload
CMD ["python", "-m", "retailtx.runtime", "doctor"]

FROM runtime AS tests
COPY tests/local ./tests/local
CMD ["python", "-m", "pytest", "-q", "-p", "no:cacheprovider"]
