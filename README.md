# bottled-lila

A self-hosted [Lichess](https://github.com/lichess-org/lila) chess server
(upstream name: lila), packaged as a Cloud in a Bottle app. It runs on your own
domain, with your own games, users and tournaments.

## What you get

- Play against Stockfish at 8 strength levels.
- All the chess variants: Crazyhouse, Chess960, King of the Hill, Three-check,
  Antichess, Atomic, Horde and Racing Kings. Games can also start from a custom
  position.
- Human against human play: shareable challenge links, lobby games, and
  correspondence games.
- Puzzles, studies and tournaments.
- An analysis board with both a local engine in the browser and server-side
  computer analysis.
- Sample users are pre-seeded, so the lobby and the leaderboards are not empty
  on the first day.

## Usage

Open the app from your Cloud in a Bottle dashboard. You arrive signed in as the
`admin` account, with no login screen to get through.

The app is public, which is what makes shared links work. Challenge links, game
links, studies and tournaments can be sent to people who do not have a Cloud in
a Bottle account, and those visitors play as anonymous guests.

Upstream signup is open, so anyone who can reach the URL can also create an
account on your instance. Share the URL with that in mind.

## Caveats

- There is no search backend. Searching for players, games, forum posts, teams
  or studies returns empty results.
- There is no SMTP. Password resets and email confirmations go nowhere;
  outgoing mail is written to the app log instead of being sent.
- The seeded sample data is stylized. The sample users are fake and the sample
  tournaments are dated around 2020.
- Lila takes 60 to 120 seconds to boot after a restart. Until it is ready, the
  app serves a self-refreshing page that says it is starting up.
- Everything runs in one container, so the whole app restarts together.

## Data

Persistent state lives under `$OPENHOST_APP_DATA_DIR`:

- the MongoDB data directory (games, users, tournaments, studies),
- the Redis append-only file,
- the generated admin credentials file.

Back up that whole directory.

## Resources

8 GiB of RAM and 4 CPU cores. This is a JVM-heavy stack: the lila server, a
WebSocket sidecar and an AI move broker each run their own JVM, and Stockfish
workers run native search while computer games or analysis are in progress.

## License

Upstream lila, lila-ws, lila-docker and lila-fishnet are AGPL-3.0, and the
bundled fishnet Stockfish worker is GPL-3.0, so the image as a whole is
AGPL-3.0. The full license text is in [LICENSE](LICENSE); the per-component
breakdown and the offer of Corresponding Source are in [NOTICE](NOTICE). The
packaging files in this repository are additionally offered under the MIT
License.

One caveat if you have commercial plans: lila bundles piece sets (and one sound
set) licensed CC BY-NC-SA for non-commercial use only, and this image ships
them, so commercial use or redistribution means stripping or relicensing those
assets first.
