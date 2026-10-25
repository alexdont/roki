TASK: add the 50 most popular anime franchises to Laev.Franchises

WHY
Roki's Lists page, "watched X of Y" progress, and "search any member to find its whole
franchise" all read laev's curated franchises (priv/franchises.json). There is no anime
franchise in it today: just "Animation", a broad filmography of studio films. So opening
Bleach shows only Bleach, with none of its films and none of Thousand-Year Blood War, which
TMDB files as a separate show (154494). The goal is to put everything related to one anime
under one umbrella, the same way Marvel, Star Wars and Alien are done.

WHAT TO DO
1. Pick the 50 most popular anime *franchises*. Rank by MyAnimeList popularity (member
   count), grouping entries into franchises (Naruto + Shippuden + Boruto + films = one).
   A franchise needs at least 2 entries; a lone film or show doesn't get a list.
   Candidates to start from (check the ranking, don't just copy this): Attack on Titan,
   Death Note, Fullmetal Alchemist, One Punch Man, Demon Slayer, My Hero Academia, Naruto,
   Sword Art Online, Tokyo Ghoul, Bleach, Jujutsu Kaisen, One Piece, Dragon Ball, Hunter x
   Hunter, Code Geass, Fairy Tail, Steins;Gate, Evangelion, Black Clover, Chainsaw Man, Spy x
   Family, Mob Psycho 100, Re:Zero, Konosuba, Haikyu!!, Fate, Gintama, JoJo's Bizarre
   Adventure, Overlord, Slime (Tensei shitara), Vinland Saga, Dr. Stone, Seven Deadly Sins,
   Fire Force, Soul Eater, Blue Exorcist, Assassination Classroom, Kaguya-sama, Frieren,
   Made in Abyss, Cowboy Bebop, Dandadan, Solo Leveling, Monogatari, Toaru (Index/Railgun),
   Gundam, Pokemon, Detective Conan, Yu-Gi-Oh!.
2. Add each as one entry in "franchises" in priv/franchises.json, in the existing shape:
   { "name": "Bleach", "entries": [ {type, tmdb_id, season?, title, date, ...} ] }
   - Every part TMDB has: the main series, sequels that TMDB files as separate shows (e.g.
     Bleach: Thousand-Year Blood War), and the theatrical films. Skip anything TMDB doesn't
     have (no OVAs or specials that exist only on MAL).
   - TV series are listed one season at a time, each with "season" and the date that season
     first aired (that is how the file keeps release order honest). Keep TMDB's seasons as
     TMDB has them; do NOT split merged cours, roki already handles that.
   - Films: type "movie", date = release date.
   - Never guess a TMDB id. Look each one up (Laev.Tmdb.search/1, or the TMDB API) and check
     type, id and year against the title before writing it.
   - Use "rename" only where TMDB's English title is unhelpful.
   - For the long ones (One Piece, Naruto, Dragon Ball, Detective Conan, Pokemon) use the
     existing "tiers" feature (see how Star Wars / Marvel define tiers) so the list can be
     shown as "Series" and "Movies" instead of one flat run.
3. Overlap: a title can sit in more than one list and the smaller list wins, so an anime
   already inside "Animation" is fine.

CHECKS BEFORE YOU HAND IT BACK
- No duplicate {type, tmdb_id} within a list; every date is ISO (YYYY-MM-DD).
- Every id resolves on TMDB. Report any you couldn't verify instead of leaving a guess.
- mix test passes, and Laev.Franchises.all/0 loads (the file is read at compile time).
- Spot-check lookups: Laev.Franchises for Bleach (tv 30984), Thousand-Year Blood War (tv 154494)
  and Bleach: Fade to Black (movie 17165) should all return the same Bleach list.

REPORT BACK
The franchises added with their entry counts, anything uncertain or missing, and release
the new package version so roki can bump to it.

ALSO LOOK AT (report, don't fix)
Laev.AnimeMap.mal_ids("tv", 30984) (Bleach, 2004) returns [269, 41467, 53998, 56784, 60636],
while mal_ids("tv", 154494) (Thousand-Year Blood War) returns [50709, 59369]. The first set
looks like it contains the Blood War cours, so the cross-id list may be mixing the two shows.
Check whether that's real.
