// /download sends the visitor to the DMG of the latest release, so the page needs no file name or version.
// The address comes from appcast.xml, the feed Remora itself updates from. The release workflow checks that
// the feed offers the DMG it publishes.
const releases = "https://github.com/sadiksaifi/remora/releases";

export default {
    async fetch(request) {
        if (new URL(request.url).pathname !== "/download") return new Response("Not found", { status: 404 });
        // If GitHub fails, stalls for five seconds, or names a file outside this repository's releases, show the release page.
        let dmg;
        try {
            // Cloudflare keeps the feed for five minutes, so most downloads make no request to GitHub.
            const feed = await fetch(`${releases}/latest/download/appcast.xml`, {
                cf: { cacheTtl: 300, cacheEverything: true },
                signal: AbortSignal.timeout(5000),
            });
            // The release notes sit in a CDATA block before the enclosure, and could quote another one.
            if (feed.ok) dmg = (await feed.text()).replace(/<!\[CDATA\[[\s\S]*?\]\]>/g, "").match(/<enclosure[^>]*\surl="([^"]+\.dmg)"/)?.[1];
        } catch {}
        return Response.redirect(dmg?.startsWith(`${releases}/download/`) ? dmg : `${releases}/latest`, 302);
    },
};
