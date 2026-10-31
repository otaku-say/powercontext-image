# PowerContext 服务端镜像
#
# 直接用 PyPI 上的官方发行包构建，不需要 clone 上游仓库：
# 上游每次发版都会同步到 PyPI，包内容与官方 docker/Dockerfile 产出的镜像一致
# （同样安装 cli + server 两个 extra，附带 Dashboard 静态资源与 powercontext 入口）。
FROM python:3.11-slim-bookworm

# 版本号由 CI 传入（解析 PyPI 最新版本或手动指定），未传入时直接构建失败
ARG POWERCONTEXT_VERSION=
RUN test -n "${POWERCONTEXT_VERSION}"

RUN pip install --no-cache-dir "powercontext[cli,server]==${POWERCONTEXT_VERSION}" \
 && groupadd --gid 10001 powercontext \
 && useradd --uid 10001 --gid powercontext --home-dir /app --no-create-home --shell /usr/sbin/nologin powercontext \
 && mkdir -p /data && chown powercontext:powercontext /data

# 容器内监听 0.0.0.0 才能被宿主机发布端口访问；对外暴露面由 compose 的
# ports: 127.0.0.1:... 与前置 nginx 控制，鉴权由 ACCESS_MODE=enforced 负责。
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    POWERCONTEXT_HOME=/data \
    POWERCONTEXT_SERVER_HTTP_HOST=0.0.0.0 \
    POWERCONTEXT_SERVER_HTTP_PORT=8000

WORKDIR /app
USER powercontext
VOLUME ["/data"]
EXPOSE 8000

# 就绪探针：/health/ready 在数据库不可用时返回 503
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health/ready', timeout=3)"]

ENTRYPOINT ["powercontext"]
CMD ["server", "run"]
