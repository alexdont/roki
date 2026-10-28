// generateUid is @InternalParsersApi, but it is exactly how the
// parsers themselves derive ids — the README's stateless-sidecar
// reconstruction depends on it (see mangaSkeleton/chapterSkeleton).
@file:OptIn(org.koitharu.kotatsu.parsers.InternalParsersApi::class)

package sidecar

import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.Application
import io.ktor.server.application.install
import io.ktor.server.engine.embeddedServer
import io.ktor.server.netty.Netty
import io.ktor.server.plugins.calllogging.CallLogging
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.response.respond
import io.ktor.server.response.respondOutputStream
import io.ktor.server.routing.get
import io.ktor.server.routing.routing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.Request
import org.koitharu.kotatsu.parsers.MangaParser
import org.koitharu.kotatsu.parsers.core.AbstractMangaParser
import org.koitharu.kotatsu.parsers.exception.AuthRequiredException
import org.koitharu.kotatsu.parsers.exception.ContentUnavailableException
import org.koitharu.kotatsu.parsers.exception.NotFoundException
import org.koitharu.kotatsu.parsers.exception.ParseException
import org.koitharu.kotatsu.parsers.exception.TooManyRequestExceptions
import org.koitharu.kotatsu.parsers.model.Manga
import org.koitharu.kotatsu.parsers.model.MangaChapter
import org.koitharu.kotatsu.parsers.model.MangaListFilter
import org.koitharu.kotatsu.parsers.model.MangaParserSource
import org.koitharu.kotatsu.parsers.model.MangaSource
import org.koitharu.kotatsu.parsers.model.RATING_UNKNOWN
import org.koitharu.kotatsu.parsers.model.SortOrder
import org.koitharu.kotatsu.parsers.util.generateUid
import org.slf4j.LoggerFactory
import sidecar.parsers.CloudFlareProtectedException
import sidecar.parsers.MangaLoaderContextImpl
import java.net.URLEncoder
import java.util.Properties
import java.util.concurrent.ConcurrentHashMap

// ── Parser registry ─────────────────────────────────────────────────

object Parsers {
    val context = MangaLoaderContextImpl()

    // Parser instances hold cookie/session state some sites need
    // across calls — cache them per source.
    private val cache = ConcurrentHashMap<MangaParserSource, MangaParser>()

    fun resolve(name: String): MangaParser {
        val source = MangaParserSource.entries.firstOrNull { it.name.equals(name, ignoreCase = true) }
            ?: throw UnknownSourceException(name)
        return cache.computeIfAbsent(source) { context.newParserInstance(it) }
    }
}

class UnknownSourceException(val name: String) : RuntimeException("Unknown source: $name")

class BadRequestException(message: String) : RuntimeException(message)

// ── Stateless model reconstruction ──────────────────────────────────
// kotatsu-parsers APIs take model objects, not bare URLs. Endpoints
// accept the identifying fields and rebuild minimal skeletons; ids
// are derived with the library's generateUid(url), which is how the
// parsers themselves build them. getDetails/getPages work fine on
// such skeletons.

private fun MangaParser.mangaSkeleton(url: String): Manga = Manga(
    id = generateUid(url),
    title = "",
    altTitles = emptySet(),
    url = url,
    publicUrl = "",
    rating = RATING_UNKNOWN,
    contentRating = null,
    coverUrl = null,
    tags = emptySet(),
    state = null,
    authors = emptySet(),
    source = source,
)

private fun MangaParser.chapterSkeleton(url: String): MangaChapter = MangaChapter(
    id = generateUid(url),
    title = null,
    number = 0f,
    volume = 0,
    url = url,
    scanlator = null,
    uploadDate = 0L,
    branch = null,
    source = source,
)

// ── JSON DTOs ───────────────────────────────────────────────────────

@Serializable
data class SourceDto(
    val name: String,
    val title: String,
    val locale: String,
    val contentType: String,
    val broken: Boolean,
    val searchSupported: Boolean,
)

@Serializable
data class MangaItemDto(
    val url: String,
    val publicUrl: String,
    val title: String,
    val coverUrl: String?,
    val source: String,
    val authors: List<String>,
    val tags: List<String>,
    val state: String?,
)

@Serializable
data class SearchResponse(val items: List<MangaItemDto>)

@Serializable
data class ChapterDto(
    val url: String,
    val title: String?,
    val number: Float,
    val volume: Int,
    val branch: String?,
    val uploadDate: Long,
    val scanlator: String?,
)

@Serializable
data class DetailsResponse(
    val url: String,
    val publicUrl: String,
    val title: String,
    val description: String?,
    val coverUrl: String?,
    val largeCoverUrl: String?,
    val state: String?,
    val authors: List<String>,
    val tags: List<String>,
    val chapters: List<ChapterDto>,
)

@Serializable
data class PageDto(
    val index: Int,
    val imageUrl: String,
    val proxyPath: String,
)

@Serializable
data class PagesResponse(val pages: List<PageDto>)

@Serializable
data class HealthResponse(val status: String, val parsersVersion: String)

@Serializable
data class ErrorResponse(val error: String, val source: String? = null, val kind: String? = null)

private fun Manga.toItemDto() = MangaItemDto(
    url = url,
    publicUrl = publicUrl,
    title = title,
    coverUrl = coverUrl,
    source = (source as? MangaParserSource)?.name ?: source.name,
    authors = authors.toList(),
    tags = tags.map { it.title },
    state = state?.name,
)

// ── Server ──────────────────────────────────────────────────────────

private val log = LoggerFactory.getLogger("sidecar")

// Computed once: instantiating a parser is offline (no requests), and
// filterCapabilities tells us whether text search actually works —
// sources without it silently return nothing for a query, which reads
// as "No results" and wastes a slot in the user's selection.
private val sourcesCatalog: List<SourceDto> by lazy {
    MangaParserSource.entries.mapNotNull { src ->
        val parser = try {
            Parsers.context.newParserInstance(src)
        } catch (e: Throwable) {
            log.warn("cannot instantiate {}: {}", src.name, e.toString())
            return@mapNotNull null
        }
        val searchable = try {
            parser.filterCapabilities.isSearchSupported
        } catch (_: Throwable) {
            false
        }
        SourceDto(
            name = src.name,
            title = src.title,
            locale = src.locale,
            contentType = src.contentType.name,
            broken = src.isBroken,
            searchSupported = searchable,
        )
    }
}

private val parsersVersion: String by lazy {
    val props = Properties()
    object {}.javaClass.getResourceAsStream("/sidecar.properties")?.use { props.load(it) }
    props.getProperty("parsersVersion", "unknown")
}

fun main() {
    val port = System.getenv("PORT")?.toIntOrNull() ?: 8420
    // No auth, so the default stays loopback-only. In roki's stack this runs as a container of
    // its own with no published port, reachable only by name on a private docker network — there
    // 127.0.0.1 would mean "unreachable", so BIND is set to 0.0.0.0 and the network is the
    // boundary instead of the interface.
    val bind = System.getenv("BIND") ?: "127.0.0.1"
    embeddedServer(Netty, port = port, host = bind, module = Application::sidecarModule)
        .start(wait = true)
}

fun Application.sidecarModule() {
    install(ContentNegotiation) {
        json(Json { encodeDefaults = true; explicitNulls = true })
    }
    install(CallLogging)
    install(StatusPages) {
        exception<UnknownSourceException> { call, e ->
            call.respond(HttpStatusCode.NotFound, ErrorResponse("unknown source", e.name, "http"))
        }
        exception<BadRequestException> { call, e ->
            call.respond(HttpStatusCode.BadRequest, ErrorResponse(e.message ?: "bad request", null, "http"))
        }
        exception<NotFoundException> { call, e ->
            call.respond(HttpStatusCode.NotFound, ErrorResponse(e.message ?: "not found", null, "http"))
        }
        exception<AuthRequiredException> { call, e ->
            call.respond(HttpStatusCode.Unauthorized, ErrorResponse(e.message ?: "auth required", null, "http"))
        }
        exception<TooManyRequestExceptions> { call, e ->
            call.respond(HttpStatusCode.TooManyRequests, ErrorResponse(e.message ?: "rate limited", null, "http"))
        }
        exception<CloudFlareProtectedException> { call, e ->
            call.respond(HttpStatusCode.BadGateway, ErrorResponse(e.message ?: "cloudflare", null, "cloudflare"))
        }
        exception<ContentUnavailableException> { call, e ->
            call.respond(HttpStatusCode.BadGateway, ErrorResponse(e.message ?: "content unavailable", null, "http"))
        }
        exception<ParseException> { call, e ->
            log.warn("parse failure", e)
            call.respond(HttpStatusCode.BadGateway, ErrorResponse(e.message ?: "parse failure", null, "parse"))
        }
        exception<Throwable> { call, e ->
            log.error("unhandled", e)
            call.respond(HttpStatusCode.BadGateway, ErrorResponse(e.message ?: "upstream failure", null, "http"))
        }
    }

    routing {
        get("/health") {
            call.respond(HealthResponse("ok", parsersVersion))
        }

        get("/sources") {
            call.respond(sourcesCatalog)
        }

        get("/sources/{name}/search") {
            val parser = Parsers.resolve(call.parameters["name"]!!)
            val q = call.request.queryParameters["q"] ?: throw BadRequestException("q is required")
            val page = call.request.queryParameters["page"]?.toIntOrNull() ?: 1
            // kotatsu list APIs are offset-based; sources learn their
            // own page size via the library's paginator. We expose a
            // simple page int and assume 20/page for offsets past the
            // first page — exact for page 1, approximate after.
            val offset = (page - 1).coerceAtLeast(0) * 20
            // The library's defaultSortOrder, not RELEVANCE: at the
            // pinned commit MangaDex renders RELEVANCE as a malformed
            // "&order&order[relevance]=desc" pair (upstream bug), and
            // the default is what the parser is actually tested with.
            val order = (parser as? AbstractMangaParser)?.defaultSortOrder
                ?: parser.availableSortOrders.first()
            val list = parser.getList(offset, order, MangaListFilter(query = q))
            call.respond(SearchResponse(list.map { it.toItemDto() }))
        }

        // Catalog browse — the source's default listing (no query),
        // e.g. for explore-page rows.
        get("/sources/{name}/list") {
            val parser = Parsers.resolve(call.parameters["name"]!!)
            val page = call.request.queryParameters["page"]?.toIntOrNull() ?: 1
            val offset = (page - 1).coerceAtLeast(0) * 20
            val order = (parser as? AbstractMangaParser)?.defaultSortOrder
                ?: parser.availableSortOrders.first()
            val list = parser.getList(offset, order, MangaListFilter.EMPTY)
            call.respond(SearchResponse(list.map { it.toItemDto() }))
        }

        get("/sources/{name}/manga") {
            val parser = Parsers.resolve(call.parameters["name"]!!)
            val url = call.request.queryParameters["url"] ?: throw BadRequestException("url is required")
            val details = parser.getDetails(parser.mangaSkeleton(url))
            call.respond(
                DetailsResponse(
                    url = details.url,
                    publicUrl = details.publicUrl,
                    title = details.title,
                    description = details.description,
                    coverUrl = details.coverUrl,
                    largeCoverUrl = details.largeCoverUrl,
                    state = details.state?.name,
                    authors = details.authors.toList(),
                    tags = details.tags.map { it.title },
                    chapters = details.chapters.orEmpty().map {
                        ChapterDto(
                            url = it.url,
                            title = it.title,
                            number = it.number,
                            volume = it.volume,
                            branch = it.branch,
                            uploadDate = it.uploadDate,
                            scanlator = it.scanlator,
                        )
                    },
                ),
            )
        }

        get("/sources/{name}/pages") {
            val name = call.parameters["name"]!!
            val parser = Parsers.resolve(name)
            val chapterUrl = call.request.queryParameters["chapterUrl"]
                ?: throw BadRequestException("chapterUrl is required")
            val pages = parser.getPages(parser.chapterSkeleton(chapterUrl))
            val dtos = pages.mapIndexed { index, page ->
                // Some sources need a second request to turn a page
                // into its final image URL.
                val imageUrl = parser.getPageUrl(page)
                PageDto(
                    index = index,
                    imageUrl = imageUrl,
                    proxyPath = "/sources/${parser.source.name}/image?url=" +
                        URLEncoder.encode(imageUrl, Charsets.UTF_8),
                )
            }
            call.respond(PagesResponse(dtos))
        }

        // Image proxy — not optional: many manga CDNs enforce
        // Referer/cookie checks, so browsers hitting imageUrl
        // directly 403. Fetching through the parser's OkHttp client
        // (tagged with the source so CommonHeadersInterceptor injects
        // the right headers) is what makes images actually load.
        get("/sources/{name}/image") {
            val parser = Parsers.resolve(call.parameters["name"]!!)
            val url = call.request.queryParameters["url"] ?: throw BadRequestException("url is required")
            val request = Request.Builder()
                .url(url)
                .tag(MangaSource::class.java, parser.source)
                .build()
            val response = runInterruptible(Dispatchers.IO) {
                Parsers.context.httpClient.newCall(request).execute()
            }
            response.use { resp ->
                if (!resp.isSuccessful) {
                    call.respond(
                        HttpStatusCode.BadGateway,
                        ErrorResponse("upstream ${resp.code}", parser.source.name, "http"),
                    )
                    return@get
                }
                val body = resp.body ?: run {
                    call.respond(
                        HttpStatusCode.BadGateway,
                        ErrorResponse("empty body", parser.source.name, "http"),
                    )
                    return@get
                }
                val contentType = body.contentType()?.toString() ?: "image/jpeg"
                call.respondOutputStream(contentType = ContentType.parse(contentType)) {
                    body.byteStream().copyTo(this)
                }
            }
        }
    }
}
