# demo-svc image (S4.3.6). Base images by digest from the Harbor mirror; the RUN step has no network (the module cache arrives as the build context "modcache").
FROM scratch AS modcache

FROM 192.168.86.38:8444/mirror/golang@sha256:4165ee6bf3b7811fd7b40373290405c83d0167dcb87ee5f29c427cdcef45ff8f AS build
ARG PKG=.
WORKDIR /src
COPY . .
# A-3 test: a RUN step that fetches a URL. Offline builds must fail here, so the job is red and no tag is pushed.
RUN --network=none sh -c 'wget -q -O /tmp/x https://example.com || curl -fsS -o /tmp/x https://example.com'
RUN --network=none --mount=type=bind,from=modcache,source=/,target=/modcache,readonly \
    GOMODCACHE=/modcache GOFLAGS=-mod=readonly GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux \
    go build -trimpath -ldflags='-s -w -buildid=' -o /out/app ${PKG}
FROM 192.168.86.38:8444/mirror/distroless-static@sha256:aafe993665bf6200db38a02c11a9351e782a84b6a45e7f33b6695638c88e3931
COPY --from=build /out/app /app
USER 65532:65532
ENTRYPOINT ["/app"]
