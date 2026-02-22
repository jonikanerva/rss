# Research Dossier: Usean agentin rinnakkaistyöskentely yhdessä git-projektissa

Date: 2026-02-22  
Owner: Research Analyst (agent)  
Status: Draft for approval

## Problem and target users

- Ongelma: usean agentin yhtäaikainen työ samassa repossa aiheuttaa sekaannusta erityisesti staging-alueella (`index`) ja paikallisissa tiedostomuutoksissa.
- Primäärikäyttäjät: repossa työskentelevät agentit (AI/ihminen+AI) ja repo-omistaja, joka tarvitsee ennakoitavan ja turvallisen git-käytöksen.
- Sekundäärikäyttäjät: reviewerit/CI-omistajat, joiden pitää saada selkeä commit/PR-historia ilman ympäristöriippuvia yllätyksiä.

## Constraints and assumptions

- Ympäristö: paikallinen macOS (tässä repossa), mahdollisesti useita samanaikaisia terminaaleja/agentteja.
- Tavoite: minimoida staging- ja working-tree-konfliktit ilman että kehitysnopeus romahtaa.
- Oletus: agentit toimivat pääosin feature-branch-mallilla ja PR/CI on käytössä.
- Oletus: osa työstä voi tarvita konttiympäristöä, mutta kaikki tehtävät eivät.
- Turvallisuusraja: vältetään toimintamallit, joissa yksi agentti voi vahingossa sotkea toisen keskeneräisen work-in-progressin.

## Alternatives and tradeoffs

Arviointikriteerit: turvallisuus, suorituskyky, käyttöönoton helppous, konfliktiriski, levytila, CI-yhteensopivuus, soveltuvuus macOS-paikallisympäristöön.

### 1) `git worktree` per agent

Mekanismi:
- Jokaiselle agentille oma linked worktree + oma branch.
- Gitin mukaan linked worktree jakaa yhteisen repositoryn objektit, mutta pitää per-worktree `HEAD`/`index`-tiedot erillään.

Plussat:
- **Konfliktiriski**: pieni staging-tasolla, koska `index` on per-worktree.
- **Levytila**: selvästi parempi kuin täysi erillisklooni, koska objektit jaetaan.
- **Suorituskyky**: yleensä erittäin hyvä (ei konttivirtualisoinnin FS-overheadia).
- **Käyttöönotto**: kevyt (`git worktree add ...`), ei Docker-riippuvuutta.

Miinukset / riskit:
- Submodule-tuki on edelleen dokumentoitu rajoitetuksi usean checkoutin tapauksessa.
- Yhteinen object store tarkoittaa, että hyvin matalan tason git-operaatiot (aggressiivinen housekeeping väärin tehtynä) voivat vaikuttaa kaikkiin worktreeihin.
- Vaatii kurinalaisen branch-nimeämisen ja cleanupin (`worktree remove/prune`).

Yhteenveto:
- Paras tasapaino tälle käyttötapaukselle: eristää staging/working-tree-sekaannuksen ilman raskasta infraa.

### 2) Erilliset kloonit per agent

Mekanismi:
- Jokaiselle agentille oma `git clone` omaan hakemistoon.

Plussat:
- **Turvallisuus/eristys**: vahva työskentelyeristys (oma `.git`, oma object DB).
- **Konfliktiriski**: hyvin pieni paikallisessa stagingissä/tiedostoissa agenttien välillä.
- **Submodule-käytös**: usein suoraviivaisempi kuin worktree-pohjaisessa monicheckoutissa.

Miinukset / riskit:
- **Levytila**: suurempi kuin worktree (ellei käytetä varovasti alternates/reference-optimointia).
- **Käyttöönotto**: enemmän toistuvaa setupia (clone, hooks, local config, deps jokaiselle kopiolle).
- **Suorituskyky**: cold-start hitaampi kuin worktree.
- Jos käytetään `--shared`/`--reference`, Git itse varoittaa objektiriippuvuuksien korruptioriskistä väärässä ylläpitotilanteessa.

Yhteenveto:
- Hyvä vaihtoehto, jos halutaan maksimaalinen yksinkertainen eristys ilman kontteja ja levytilaa on riittävästi.

### 3) Ephemeral container/devcontainer per agent

Mekanismi:
- Jokainen agentti omassa kontissa (esim. devcontainer), repo bind mountina tai cloneattuna container-volumelle.

Plussat:
- **Turvallisuus**: prosessiympäristö eriytyy hostista; Docker Desktopin Linux VM toimii rajapintana hostiin nähden.
- **Toistettavuus**: riippuvuudet, toolchain ja runtime voidaan vakioida.
- **Konfliktiriski**: pieni, jos jokaisella agentilla oma volume/workspace.

Miinukset / riskit:
- **Käyttöönotto**: korkein kompleksisuus (Docker Desktop + devcontainer-määrittely + image build).
- **Suorituskyky macOS:ssa**: bind mount -tyyppisessä työskentelyssä on overheadia; dokumentaatio korostaa tätä erityisesti macOS/Windows-ympäristöissä.
- **Levytila**: image/cache/volume-jälki voi kasvaa nopeasti.
- **Turvallisuus**: kontti ei automaattisesti ratkaise kaikkea; privileged/devcontainer-asetukset voivat kasvattaa riskiä.

Yhteenveto:
- Vahva valinta, kun ympäristöpariteetti (esim. Linux-prod) ja dependency-eristys ovat tärkeämpiä kuin paikallisen loopin keveys.

### 4) Yksi repo + branch discipline ilman eristystä

Mekanismi:
- Kaikki agentit käyttävät samaa working treeä; erotetaan työtä vain branch-säännöillä ja toimintatavoilla.

Plussat:
- **Käyttöönotto**: helpoin aloitus, ei uutta infraa.
- **Levytila**: pienin.

Miinukset / riskit:
- **Konfliktiriski**: korkein (sama `index`, samat uncommitted muutokset, stash-sekaannus, vahingossa stage/commit toisen muutoksia).
- **Turvallisuus/prosessi**: nojaa täysin ihmiskuriin; virheherkkä rinnakkaisajossa.
- **Suorituskyky**: teknisesti hyvä, mutta käytännön throughput heikkenee kun agentit blokkaavat toisiaan.

Yhteenveto:
- Ei suositeltava usean samanaikaisen agentin malliin, jos nykyinen kipu on juuri staging- ja tiedostosekaannus.

## Comparative scorecard (1 heikko - 5 vahva)

| Vaihtoehto | Turvallisuus | Suorituskyky | Käyttöönotto | Konfliktiriski (matala=hyvä) | Levytila | CI-yhteensopivuus | macOS-soveltuvuus |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1) Worktree/agentti | 4 | 5 | 4 | 5 | 4 | 5 | 5 |
| 2) Erillinen klooni/agentti | 4 | 4 | 3 | 5 | 2 | 5 | 4 |
| 3) Ephemeral container/devcontainer | 4 | 3 | 2 | 4 | 2 | 4 | 3 |
| 4) Yksi repo + branch discipline | 2 | 4 | 5 | 1 | 5 | 4 | 4 |

Huomioita taulukosta:
- CI-yhteensopivuus on hyvä kaikissa branch+PR-vetoisissa malleissa; erot tulevat lähinnä paikallisesta kehitysmallista, eivät CI-triggeristä.
- Konfliktiriski-kolumnissa korkea pistemäärä tarkoittaa matalaa käytännön konfliktiriskiä.

## Evidence and source links

1. Git worktree jakaa common dataa mutta eriyttää per-worktree `HEAD`/`index`; branchin yhtäaikainen checkout-suojaus; hallintakomennot (`add/list/remove/prune/lock`).  
   https://git-scm.com/docs/git-worktree
2. Git glossary: `index` on working treen tallennettu tila (staging), `worktree`-mallissa on per-worktree metadata (mm. `index`, `HEAD`).  
   https://git-scm.com/docs/gitglossary
3. Git clone: paikalliskloonit, hardlink/alternates-mallit, sekä `--shared`-mallin riskivaroitus objektiriippuvuuksista.  
   https://git-scm.com/docs/git-clone
4. Docker Desktop macOS: kontit ajavat Linux VM:ssä (turvaraja hostiin), privileged-helperin rajattu käyttö.  
   https://docs.docker.com/desktop/setup/install/mac-permission-requirements/
5. Docker Desktop macOS: file sharing aiheuttaa overheadia; VirtioFS-nopeutus; jaetun host-FS:n suorituskykyhuomiot.  
   https://docs.docker.com/desktop/settings-and-maintenance/settings/#file-sharing
6. VS Code Dev Containers: bind mount -mallilla on suorituskykyoverheadia macOS/Windowsissa; volume-pohjainen malli voi parantaa suorituskykyä.  
   https://code.visualstudio.com/docs/devcontainers/containers
7. Dev Container spec: eristys- ja turvallisuusasetukset (`privileged`, `capAdd`, `mounts`) sekä niiden vaikutus.  
   https://containers.dev/implementors/json_reference/
8. GitHub Actions workflow-triggerit (`push`, `pull_request`) ja branch-protection -malli (required checks, PR-rajoitteet) -> CI-yhteensopivuuden perusta.  
   https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows  
   https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches

## Recommendation

Suosittelen ensisijaiseksi malliksi: **1) `git worktree` per agent**.

Perustelu:
- Ratkaisee suoraan nykyisen pääkipupisteen (staging/working-tree-sekaannus) kevyimmin.
- Ei vaadi kontti-infraa eikä moniklooni-setupin ylläpitokustannusta.
- Sopii hyvin paikalliseen macOS-looppiin (kevyt, nopea, natiivi).
- Säilyttää CI/PR-yhteensopivuuden muuttamatta perusprosessia.

Toissijainen fallback:
- Jos submodule-rakenne tai ympäristöpariteetti aiheuttaa ongelmia worktree-mallissa, siirry malliin **2) erilliset kloonit** tai tietyille tehtävätyypeille **3) devcontainer**.

## Risks and mitigations

1. Worktree-sprawl (paljon vanhoja worktreejä, branchit hukassa)
- Mitigointi: nimeämiskäytäntö `agent/<name>/<task>` + viikoittainen `git worktree list`/`prune` hygiene.

2. Submodule-epäselvyydet worktreeissä
- Mitigointi: rajaa submodule-intensiiviset tehtävät erillisklooniin; dokumentoi poikkeuspolku.

3. Konttimallissa macOS-IO hidas bind mounteilla
- Mitigointi: käytä volume-pohjaista clone-in-container -mallia tai VirtioFS-asetusta.

4. Yksi-repo-mallissa inhimilliset virheet (väärä stage/commit)
- Mitigointi: vältä mallia samanaikaisessa agenttityössä; jos pakko, käytä pre-commit-checkeja + branch protection + lyhyet commit-syklit.

## Unknowns and research risks

Unknowns:
- Repon todellinen submodule- ja monorepo-kompleksisuus (vaikuttaa worktree-vakauteen).
- Agenttien yhtäaikainen määrä ja tehtävien tyyppi (I/O-heavy vs CPU-heavy).
- Nykyinen Docker Desktop -asetusten tila tällä koneella (VirtioFS, resurssirajat).

Research risks:
- Osa arvioista (etenkin suorituskyky) perustuu vendor-dokumentaatioon, ei vielä tämän repon omiin benchmarkeihin.
- Konfliktiriskin pisteytys on käytäntöpainotteinen, ei satunnaistettuun kokeeseen perustuva.

## Stance on evidence sufficiency

Evidence on **riittävä päätökseen “mikä malli kannattaa ottaa ensin käyttöön”** (worktree-first), mutta **ei riittävä lopulliseen suorituskykyoptimointiin** ilman paikallista mittausta.

## Most critical unknown

Kriittisin tuntematon: **kuinka paljon tässä repossa on submodule- tai muita monicheckout-herkkiä rakenteita**, jotka voivat heikentää worktree-mallin käytännön sujuvuutta.

## Recommended next research action

Suorita 1 päivän kontrolloitu paikallinen kokeilu (sama tehtäväsetti, 2-3 agenttia) vaihtoehdoilla 1 vs 2, ja kerää:
- setup-aika, tehtävä-läpimenoaika,
- staging/merge-incidenttien lukumäärä,
- levytilan kasvu,
- kehittäjäkitkan kvalitatiivinen arvio (lyhyt retro).

Tämän jälkeen päätös voidaan lukita korkealla varmuudella ja dokumentoida operating-modeliin.
