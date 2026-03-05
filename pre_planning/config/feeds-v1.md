# Feed Fetch Definition (v1 Reset)

This file defines which feeds/sources are used when building the review queue for local LLM validation.

## Source of truth

- Full Feedbin subscription snapshot: `config/feedbin-feeds-v1.json`

## Fetch behavior

- Input endpoint: Feedbin `GET /v2/entries.json`
- Include read entries: `true`
- Max items: `200`
- Source includes only: 
  - `https://www.theverge.com/rss/index.xml`
  - `https://www.techmeme.com/feed.xml`
  - `https://www.eurogamer.net/feed`
  - `https://daringfireball.net/feeds/main`
  - `https://sixcolors.com/?feed=json`
  - `https://www.notateslaapp.com/rss`
  - `https://www.gamesindustry.biz/rss/gamesindustry_news_feed.rss`
  - `https://mp1st.com/feed`
  - `https://feeds.yle.fi/uutiset/v1/majorHeadlines/YLE_UUTISET.rss`
  - `https://techcrunch.com/feed/`
  - `https://www.gamedeveloper.com/rss.xml`

