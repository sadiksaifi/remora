// /download sends the visitor to the DMG of the latest release, so the page needs no file name or version.
// The address comes from appcast.xml, the feed Remora itself updates from. The release workflow checks that
// the feed offers the DMG it publishes.
const releases = "https://github.com/sadiksaifi/remora/releases";

export default {
    async fetch(request) {
        if (new URL(request.url).pathname !== "/download") return new Response("Not found", { status: 404 });
        // Cloudflare keeps the feed for five minutes, so most downloads make no request to GitHub.
        const feed = await fetch(`${releases}/latest/download/appcast.xml`, { cf: { cacheTtl: 300, cacheEverything: true } });
        const dmg = feed.ok ? (await feed.text()).match(/<enclosure[^>]*\surl="([^"]+\.dmg)"/)?.[1] : undefined;
        // If the feed is missing or names a file outside this repository's releases, show the release page.
        return Response.redirect(dmg?.startsWith(`${releases}/download/`) ? dmg : `${releases}/latest`, 302);
    },
};
