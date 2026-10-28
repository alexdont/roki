// Adapted from kotatsu-dl, made source-aware for per-source
// overrides.
package sidecar.parsers

import org.koitharu.kotatsu.parsers.config.ConfigKey
import org.koitharu.kotatsu.parsers.config.MangaSourceConfig
import org.koitharu.kotatsu.parsers.model.MangaParserSource
import org.koitharu.kotatsu.parsers.model.MangaSource
import org.koitharu.kotatsu.parsers.network.UserAgents

class DefaultMangaSourceConfig(
    private val source: MangaSource? = null,
) : MangaSourceConfig {

    override fun <T> get(key: ConfigKey<T>): T {
        // MangaDex's API host REJECTS browser user agents (inverted
        // anti-scraping: real browsers have no business on
        // api.mangadex.org, so Mozilla/* gets an HTML 400 block
        // page). The Kotatsu app UA is welcome — use it there while
        // every scraper source keeps the browser UA it needs.
        if (key is ConfigKey.UserAgent &&
            source is MangaParserSource &&
            source.name.startsWith("MANGADEX")
        ) {
            @Suppress("UNCHECKED_CAST")
            return UserAgents.KOTATSU as T
        }
        return key.defaultValue
    }
}
