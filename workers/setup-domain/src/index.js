export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "") {
      return Response.redirect("https://github.com/simoncrypta/agentic-dev-setup", 301);
    }
    const upstream = new URL(`https://agentic-dev-setup.pages.dev${url.pathname}${url.search}`);
    return fetch(upstream, request);
  },
};
