#!/usr/bin/env python3
"""MarkItDown MCP Server — SSE transport.

Exposes markitdown document conversion as MCP tools over HTTP (SSE).
OpenClaw connects to this server via mcporter configuration.

Tools exposed:
  - convert: Convert a file or URL to Markdown
  - convert_text: Convert raw text content to Markdown
"""
import argparse
import tempfile
import urllib.request
from pathlib import Path

from markitdown import MarkItDown
from mcp.server.fastmcp import FastMCP
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route

mcp = FastMCP(
    name="markitdown",
)

_md = MarkItDown()


@mcp.tool()
def convert(source: str) -> str:
    """Convert a document (file path or URL) to Markdown.

    Supports: PDF, DOCX, PPTX, XLSX, HTML, CSV, JSON, XML, images, and more.

    Args:
        source: A file path or URL pointing to the document to convert.

    Returns:
        The converted Markdown text.
    """
    try:
        if source.startswith(("http://", "https://")):
            suffix = Path(source.split("?")[0]).suffix or ".tmp"
            tmp = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
            try:
                urllib.request.urlretrieve(source, tmp.name)
                result = _md.convert(tmp.name)
            finally:
                Path(tmp.name).unlink(missing_ok=True)
        else:
            result = _md.convert(source)
        return result.text_content
    except Exception as e:
        return f"Error converting document: {e}"


@mcp.tool()
def convert_text(text: str, source_type: str = "html") -> str:
    """Convert raw text content to Markdown.

    Args:
        text: The raw text content to convert.
        source_type: The format of the input text (e.g. 'html', 'csv').

    Returns:
        The converted Markdown text.
    """
    try:
        suffix = f".{source_type}"
        tmp = tempfile.NamedTemporaryFile(
            delete=False, suffix=suffix, mode="w", encoding="utf-8"
        )
        try:
            tmp.write(text)
            tmp.flush()
            tmp.close()
            result = _md.convert(tmp.name)
        finally:
            Path(tmp.name).unlink(missing_ok=True)
        return result.text_content
    except Exception as e:
        return f"Error converting text: {e}"


# ---------------------------------------------------------------------------
# Health endpoint for Docker healthcheck
# ---------------------------------------------------------------------------
async def health(request):
    return JSONResponse({"status": "ok", "service": "markitdown-mcp"})


def main():
    parser = argparse.ArgumentParser(description="MarkItDown MCP Server")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=3001)
    args = parser.parse_args()

    mcp.settings.host = args.host
    mcp.settings.port = args.port

    # Get the SSE ASGI app from FastMCP and compose with health route
    sse_app = mcp.sse_app()
    app = Starlette(
        routes=[
            Route("/health", health),
            Mount("/", app=sse_app),
        ]
    )

    import uvicorn

    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
