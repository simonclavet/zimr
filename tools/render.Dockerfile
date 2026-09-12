# Dockerfile for deploying the zimr signaling server (render_server) to Render.
#
# render_server is a fully static Linux binary (built for x86_64-linux-musl), so
# it needs almost nothing around it. Alpine is tiny and gives a shell if needed.
FROM alpine:3.20

# Copy the prebuilt server binary in. (Both this file and `render_server` must be
# at the ROOT of your GitHub repo.)
COPY render_server /usr/local/bin/render_server

# GitHub's web "Upload files" stores files as non-executable, so make it runnable.
RUN chmod +x /usr/local/bin/render_server

# Render injects PORT (default 10000) and routes external https/wss traffic to it.
# The server reads PORT and listens on 0.0.0.0. EXPOSE just documents the port.
EXPOSE 10000

CMD ["/usr/local/bin/render_server"]
