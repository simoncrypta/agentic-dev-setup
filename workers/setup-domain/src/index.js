const GITHUB_RAW =
  "https://raw.githubusercontent.com/simoncrypta/agentic-dev-setup/master";
const GITHUB_REPO = "https://github.com/simoncrypta/agentic-dev-setup";

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "") {
      return Response.redirect(GITHUB_REPO, 301);
    }

    const upstream = new URL(`${GITHUB_RAW}${url.pathname}${url.search}`);
    const response = await fetch(upstream, {
      headers: { "User-Agent": "agentic-dev-setup-cdn" },
      cf: { cacheTtl: 60, cacheEverything: true },
    });

    if (response.status === 404) {
      return new Response("Not found\n", { status: 404 });
    }

    // Preserve body; set a stable content-type for shell assets.
    const headers = new Headers(response.headers);
    if (url.pathname.endsWith(".sh") || url.pathname.endsWith(".toml")) {
      headers.set("Content-Type", "text/plain; charset=utf-8");
    }
    headers.set("Cache-Control", "public, max-age=60");

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  },
};
