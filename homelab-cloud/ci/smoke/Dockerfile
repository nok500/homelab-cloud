# The CI smoke image (ADR 0015): proves the build path end to end (git context at the commit, rootless BuildKit
# running a RUN step, push to Harbor project ci). No `# syntax=` line: BuildKit's built-in Dockerfile frontend,
# nothing else pulled.
FROM docker.io/library/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
RUN echo "built by the lab CI: Argo Workflows + rootless BuildKit" > /ci-smoke.txt
USER 65532:65532
CMD ["cat", "/ci-smoke.txt"]
