# Lernpfad: Eg-walker in Swift

Dieses Dokument begleitet den Code. Es erklärt die Konzepte in der Reihenfolge, in der wir sie gebaut haben, und hält fest, *warum* Entscheidungen so gefallen sind. Messungen und widerlegte Hypothesen gehören ausdrücklich dazu. Am Ende jedes Kapitels steht eine kleine Übung.

---

## 1. Das Problem

Mehrere Leute bearbeiten denselben Text, teils offline. Am Ende sollen alle denselben Text sehen, und zwar einen, der „vernünftig“ aussieht: Wörter, die zwei Personen gleichzeitig an derselben Stelle tippen, sollen nicht buchstabenweise verschränkt werden.

Dafür gab es bisher zwei Schulen:

| | Operational Transformation (OT) | CRDT (z. B. Yjs, Automerge) |
|---|---|---|
| Operationen | „füge `x` an Position 5 ein“ | „füge `x` nach Zeichen-ID `(alice, 17)` ein“ |
| Stärke | kompakt, Laden schnell | Mergen beliebig divergierter Stände in O(n log n) |
| Schwäche | Mergen lang divergierter Branches O(n²) oder schlechter | jedes Zeichen trägt dauerhaft Metadaten, Laden ist teuer |

**Eg-walker** (Gentle, Kleppmann, EuroSys 2025) kombiniert beides. Gespeichert wird nur der *Event-Graph* mit OT-artigen Operationen (Integer-Positionen). Nur wenn wirklich nebenläufige Events gemergt werden müssen, baut der Walker *temporär* einen CRDT-Zustand auf und verwirft ihn danach wieder.

**Übung 1:** Überleg dir, warum „Position 5“ allein nicht reicht, sobald zwei Leute gleichzeitig editieren. Konstruiere ein Beispiel, in dem naives Anwenden zu unterschiedlichen Ergebnissen auf zwei Replikas führt.

---

## 2. Der Causal Graph (`CausalGraph.swift`)

- Jedes Event (ein eingefügtes oder gelöschtes Zeichen) hat eine globale ID `(agent, seq)`.
- Lokal nummerieren wir Events einfach 0, 1, 2, … in der Reihenfolge, in der wir sie erfahren: die **Local Version (LV)**. Weil ein Event erst nach seinen Eltern ankommt, ist die LV-Reihenfolge **immer eine topologische Sortierung**. Der ganze Algorithmus stützt sich darauf.
- Die **Frontier** (`heads`) ist die Menge der Events, von denen noch nichts abhängt, also „die aktuelle Version“.
- **Run-Length-Encoding:** Tippt jemand „Hallo“, entstehen 5 Events. Jedes hat genau ein Elternteil, nämlich das vorige. Wir speichern das als *einen* `CGEntry`.

Die zentralen Graph-Algorithmen laufen alle *rückwärts in der Zeit* mit einem Max-Heap: Man nimmt die höchste LV heraus und ersetzt sie durch ihre Eltern.
- `diff(a, b)`: welche Events nur in der Geschichte von a bzw. b liegen. Das braucht der Walker, um seinen Zustand von einer Version zur anderen zu bewegen.
- `findDominators`, `versionContains`, `findConflicting`.

**Swift-Lektion: ARC ist der heimliche Gegner.** Ursprünglich hatte `CGEntry` ein Feld `parents: [LV]`. Jede Kopie eines Entries, und der Walker liest Entries millionenfach, bedeutete dann Retain und Release auf dem Array-Buffer. Jetzt liegen die Eltern in einem flachen `parentPool`, und der Entry ist *POD* (plain old data, ohne Refcounting). Allein das hat den Diff etwa 3× schneller gemacht.

**Swift-Lektion: `String`-Gleichheit ist Unicode-kanonisch.** `"ö" == "o\u{308}"` ist in Swift `true`. Ein Trace aus dem Node.js-Repository enthält den Autor „Felix Geisendörfer“ in *beiden* Normalformen. Für Rust und JS sind das zwei Agents, für ein `[String: AgentID]`-Dictionary einer. Die Folge: Sequenznummern kollidierten, Events gingen verloren. Gefunden hat das ein Test mit echten Daten. Der Fix: Agents werden über ihre UTF-8-Bytes identifiziert (`agentIDs: [[UInt8]: AgentID]`), mit Regressionstest.

**Übung 2:** Lies `diff()` und spiel es auf Papier mit zwei Branches durch, die sich bei LV 3 trennen. Warum wird `markRun(v2 + 1, v, flag)` mit `+ 1` aufgerufen?

---

## 3. Der Referenz-Walker (`Reference/ReferenceWalker.swift`)

Eine bewusst naive, zeilengetreue Portierung von Joseph Gentles TypeScript-Referenz. Er ist O(n²) und langsam, und das ist Absicht: Er ist das **Orakel**, gegen das die schnelle Engine getestet wird.

Kernbegriffe:
- **Item:** ein eingefügtes Zeichen im CRDT-Zustand, mit `originLeft` (das Zeichen links beim Einfügen) und `rightParent` (Fugue-Regel).
- **Zwei Zustände pro Item:**
  - `curState`: Zustand bei der Version, an der der Walker *gerade* steht (NYI = not yet inserted, Inserted, Deleted×n). Er bewegt sich vor und zurück.
  - `endState`: Zustand, wenn *alles* gemergt ist. Daraus ergibt sich die Position im fertigen Dokument.
- **Retreat/Advance:** Um ein Event mit Eltern P anzuwenden, bewegt der Walker seinen `curState` per `diff(curVersion, P)` zur Version P. Danach ist die Integer-Position des Events gültig, und er findet das Ziel-Item.
- **Integrate (YjsMod/Fugue):** Fügen zwei Leute gleichzeitig an derselben Stelle ein, entscheidet die Reihenfolge der Origins und am Ende der Agent-Name. Das ist der Teil, der das Verschränken von Wörtern verhindert.

**Fallstrick, der uns begegnet ist:** Der Kommentar in der TS-Referenz spricht von „FugueMax“, der Code nutzt aber die *Fugue*-Regel (`rightParent` nur, wenn das nächste Item denselben `originLeft` hat). diamond-types nutzt eine YjsMod-Variante. Auf allen Testdaten kommt dasselbe heraus. Wir haben die TS-Semantik übernommen, weil sie gegen die Konformanz-Suite von diamond-types verifiziert ist.

**Übung 3:** Zwei Agents fügen gleichzeitig „A“ und „B“ an Position 0 ein. Welches Ergebnis entsteht, und warum hängt es vom Agent-Namen ab?

---

## 4. Die optimierte Engine (`Engine/`)

### 4.1 Kritische Versionen und Fast-Forward (`Walker.plan`)

Ein Event x ist **kritisch**, wenn
- (a) alles vor x in seiner Geschichte liegt (die Frontier nach x ist genau `[x]`), und
- (b) alles nach x von x abstammt (kein späteres Event hat ein Elternteil < x).

Dann kann *keine* Nebenläufigkeit x berühren. Seine Integer-Position ist also schon korrekt, und wir wenden es **direkt auf den Text an, ganz ohne CRDT**. Sequenzielle Traces (S1–S3) bauen deshalb nie einen CRDT. Zwischen zwei kritischen Events baut der Walker einen Tracker auf und wirft ihn am nächsten kritischen Event wieder weg.

Beide Bedingungen lassen sich in O(n) über die RLE-Entries vorberechnen: (a) über die Frontier-Größe beim Durchlaufen, (b) über ein Suffix-Minimum der Eltern. Innerhalb eines Entries sind die kritischen Events immer ein *Präfix*. Warum das so ist, steht im Code-Kommentar.

**Placeholder:** Startet der Tracker mitten im Dokument, steht ein einziger Span für die bestehenden N Zeichen. Er bekommt reservierte LVs ab `placeholderBase`. Wird ein Placeholder gelöscht, wird nur das betroffene Stück vom Span abgespalten.

### 4.2 Der `ItemTree` (B-Baum in einer Arena)

- Items werden als **Spans** gespeichert. Ein Lauf getippter Zeichen ist *ein* Span, und nur das erste Item trägt Origins. Für Item i > 0 gilt immer `originLeft = lv + i - 1` und kein `rightParent`. Beim Integrieren kann man deshalb ganze Spans auf einmal überspringen. diamond-types nutzt dieselbe Einsicht.
- Jeder innere Knoten speichert pro Kind aggregierte Breiten (`Agg`: sichtbar jetzt, sichtbar am Ende, alle Items, Placeholder). So findet der Baum „das 37. sichtbare Zeichen“ in O(log n), und ebenso den Rang eines Items.
- **Arena statt Objekte:** Knoten verweisen per `Int32`-Index aufeinander, die Daten liegen in flachen, manuell verwalteten Puffern. Das heißt: kein ARC, keine Allokation pro Knoten, Leeren in O(1). Der Preis sind `Unsafe*Pointer`. Dafür gibt es `checkInvariants()` (es prüft *jedes* Aggregat und jeden Index), Fuzzing mit Validierung nach jedem Schritt und einen AddressSanitizer-Lauf.

**Bug, den der allererste Testlauf fand:** `moveUpdate(from:count:)` darf sich nicht überlappen, ein Verschieben innerhalb eines Blatts überlappt aber natürlich. Swift fängt das im Debug-Build ab („moveUpdate overlapping range“). Die Lösung ist ein kleines `memmoveElements` (raw `copyMemory`, also memmove-Semantik) für triviale Typen.

### 4.3 Performance-Lektionen (alle gemessen, mit callgrind)

| Änderung | Effekt | Lehre |
|---|---|---|
| Eltern als flacher Pool statt `[LV]` im Entry | Diff ~3× schneller | POD-Structs, kein ARC im Hot Path |
| Allokationsfreier Diff (sortiertes Int-Array statt Dictionary/Heap) | C1 195 → 150 ms | Kleine Daten brauchen kleine Strukturen. Hashing kostet mehr als Linearsuche über 3 Elemente |
| `@exclusivity(unchecked)` auf heißen Klassenfeldern | C1 150 → 71 ms | Swift prüft Exklusivität bei Klassen-`var`s *zur Laufzeit*. Gezielt abschalten, begründen, testen |
| Rohe Pointer-Sichten aufs Oplog während des Checkouts | weniger Retain/Release | `withUnsafeBufferPointer` um den ganzen Walk, nichts entkommt dem Scope |
| Span-Split ohne Aggregat-Propagation | A2 −15 % | Ein Split ändert keine Summe, also nichts nach oben melden |
| **Greedy „folge dem Kind“-Reihenfolge** | **0 %** | Hypothese widerlegt. Die Python-Simulation zeigte den Grund |
| **DFS, kleinster Teilbaum zuerst** (Regionen ≥ 64 Entries) | A2 120 → 51 ms, A1 42 → 20 ms | Retreat/Advance-Arbeit bei A2 von 6,0 M auf 2,4 M |
| **Gechunkter Text-Buffer statt Gap-Buffer** | schlechter, verworfen | Callgrind zeigte memmove bei ~2 %. Dem Profil glauben, nicht der Intuition |

Zur Traversal-Reihenfolge: Jede topologische Reihenfolge liefert dasselbe Dokument, aber die Kosten unterscheiden sich stark. Bei einem Fork mit kleinem Branch S und großem L, die später mergen, kostet „S zuerst“ 2·|S| Tracker-Bewegung, „L zuerst“ 2·|L|. Der Effekt ist bei den C-Traces (zwei Autoren, die sich ständig synchronisieren) aber negativ: weniger Bewegung, trotzdem langsamer. Wahrscheinlich liegt das an der Cache-Lokalität. Deshalb gibt es eine empirische Schwelle (`dfsMinEntries = 64`). Ehrlich gesagt ist das eine Heuristik und keine Theorie. Ein besseres Kostenmodell wäre ein gutes Folgeprojekt.

**Übung 4:** Nimm `Scripts/simulate-order.py` und berechne die Retreat/Advance-Kosten für LV-Reihenfolge und DFS auf C1. Erklärt die Simulation, warum DFS dort nicht hilft?

---

## 5. Zuverlässigkeit: die Testpyramide

| Ebene | Was | Datei |
|---|---|---|
| Unit | Lokales Editieren, Konkurrenz, Agent-Bytes-Regression | `EngineTests.swift` |
| Konformanz | Tausende Fälle aus diamond-types, mit **Baum-Validierung nach jedem Schritt** | `conformanceSuite` |
| Echte Historien | Git-Historien (node, git-makefile) und Paper-Traces S1–A2, byte-identisch zu diamond-types, beide Traversal-Reihenfolgen | `rawTraces`, `dtExported` |
| Differential-Fuzzing | Zufällige Multi-Replica-Sessions. Optimiert == Referenz-Orakel, Konvergenz, Invarianten. Unicode inkl. Emoji und Kombinationszeichen | `FuzzTests.swift` |
| Mutation Testing | Sind die Tests scharf genug? | `Scripts/mutate.py` |
| Sanitizer | AddressSanitizer über die ganze Suite | `swift test --sanitize=address` |

**Die A2-Geschichte:** Auf dem anonymisierten Paper-Trace A2.json stimmte unser Ergebnis nicht mit `endContent` überein, die Länge aber schon. Ein Bug? Nein. Das anonymisierte Format ersetzt Agent-Namen durch Zahlen, und bei gleichzeitigen Inserts an derselben Stelle entscheidet der Name. diamond-types warnt beim Export selbst davor. Mit einem eigenen Exporter (`dt-export`), der die *Originalnamen* aus der `.dt`-Datei erhält, ist A2 byte-identisch. Lehre: Erst klären, ob das Orakel überhaupt die richtige Frage beantwortet.

**Fuzzer-Design:** Jeder Fall entsteht aus einem Seed (SplitMix64), damit jeder Fehler reproduzierbar ist (`EGWALKER_FUZZ_SEED`). Für Soak-Runs gibt es `EGWALKER_FUZZ_ITERS=100000`.

---

## 6. Mutation Testing

Mutation Testing beantwortet die Frage: *Würden meine Tests es merken, wenn dieser Code falsch wäre?* Der Runner (`Scripts/mutate.py`) baut nacheinander kleine, plausible Bugs ein, zum Beispiel `<` → `<=`, `+= 1` → `-= 1` oder `&&` → `||`. Nach jedem Einbau baut er neu und lässt ein schnelles, aber scharfes Test-Gate laufen (Konformanz, echte Traces, 60 Fuzz-Seeds, ~12 s).

- **Killed:** Die Tests schlagen fehl. Gut.
- **Survived:** Die Tests sind trotzdem grün. Entweder haben sie hier einen blinden Fleck, oder der Mutant ist *äquivalent*, ändert also das Verhalten gar nicht. Das muss ein Mensch entscheiden. Genau darin liegt der Wert der Methode.

**Ergebnis:** 110 zufällig gezogene Mutanten aus 869 Kandidaten. Roh: 93 getötet, 17 überlebt, **84,5 %**. Nach der Triage (`Benchmarks/mutation/TRIAGE.md`):

| Kategorie | Anzahl | Was wir getan haben |
|---|---|---|
| Echte Testlücke | 6 | 5 neue Tests plus Debug-Asserts, jeweils mit `--verify` bestätigt, dass der Mutant jetzt stirbt |
| Nur Performance | 4 | bleiben, abgesichert durch die Benchmarks |
| Nur Metrik | 2 | bleiben |
| Äquivalent | 5 | bleiben, Begründung dokumentiert |

Danach sind **99/110 getötet (90 %)**, und **jeder verhaltensändernde Mutant der Stichprobe stirbt**.

Was die Überlebenden gelehrt haben:
1. **Ausgabe-Tests sehen keine Kompaktheit.** Wird die RLE-Verschmelzung kaputt gemacht, kommt derselbe Text heraus, nur mit mehr Speicher und langsamer. Lösung: Tests auf Struktur (`entryCount`, `runCount`) und die Invariante „keine zwei benachbarten verschmelzbaren Spans“.
2. **Ein Test kann zufällig blind sein.** Unser RLE-Test tippte ab LV 0, und genau dort sind `a - 0` und `a + 0` gleich. Ein Mutant hat das sichtbar gemacht.
3. **Unsafe Pointer trappen nicht.** `idx > 0` → `idx >= 0` liest Span −1 aus fremdem Speicher, und kein Test merkt es. Jetzt gibt es `assert`-Bounds-Checks in den Raw-Accessoren (nur im Debug-Build, kosten im Release nichts).
4. **Gate ≠ Suite.** Ein Mutant überlebte nur, weil das schnelle Gate einen relevanten Test nicht enthielt. Deshalb kann man jeden Überlebenden zusätzlich gegen die volle Suite prüfen (`--recheck`).
5. **Fuzzer brauchen Szenarien, nicht nur Zufall.** Der Zufallsfuzzer hat nie eine Backspace-Serie erzeugt, deren Mitte ein anderer Branch referenziert. Der neue Test baut genau dieses Muster gezielt, mit 300 Seeds.

**Übung 6:** Nimm einen der „nur Performance“-Mutanten und überleg dir einen Test, der ihn tötet, ohne von Timing abzuhängen. Tipp: Zähle Operationen, nicht Millisekunden (siehe `WalkerStats`).

---

## 7. Benchmarks

Gemessen mit `Scripts/bench.sh` auf derselben 2-Kern-VM (Intel Xeon @ 2,1 GHz, Linux). Swift und Rust laufen abwechselnd, damit Störungen beide gleich treffen. Gemessen wird `checkout` eines bereits geladenen Oplogs, also das, was das Paper „merge time“ nennt. Speicher ist der Peak-Heap-Zuwachs während eines Checkouts, für beide mit demselben `LD_PRELOAD`-malloc-Tracker gemessen (`Benchmarks/memtrack`).

| Trace | Ops | Swift | Rust (diamond-types) | Rust/Swift | Heap Swift | Heap Rust |
|---|---|---|---|---|---|---|
| S1 | 779k | 1,98 ms | 4,05 ms | **2,05×** | 0,33 MB | 1,39 MB |
| S2 | 1,1M | 3,50 ms | 6,04 ms | **1,73×** | 0,41 MB | 0,88 MB |
| S3 | 2,3M | 5,49 ms | 8,21 ms | **1,50×** | 1,17 MB | 0,86 MB |
| C1 | 652k | 74,6 ms | 105,1 ms | **1,41×** | **1,14 MB** | 42,7 MB |
| C2 | 608k | 107,3 ms | 153,6 ms | **1,43×** | **1,63 MB** | 50,4 MB |
| A1 | 947k | 21,7 ms | 18,8 ms | 0,87× | 3,02 MB | 3,16 MB |
| A2 | 698k | 53,8 ms | 50,5 ms | 0,94× | 6,99 MB | 5,83 MB |

Alle Swift-Ergebnisse sind byte-identisch mit diamond-types (Spalte „Correct“ in `Benchmarks/results/RESULTS.md`).

**Einordnung, ehrlich:**
- Das Ziel „Rust in Geschwindigkeit, Ressourcen und Zuverlässigkeit schlagen“ ist **teilweise erreicht**. Bei der Geschwindigkeit gewinnt Swift auf 5 von 7 Traces, bei A1/A2 liegt es 6–13 % zurück. Beim Speicher gewinnt Swift auf 5 von 7 Traces, auf C1/C2 dramatisch (37× weniger Peak), auf S3/A2 nicht.
- Woher kommt der C-Vorsprung? Unser Tracker wird an *jeder* kritischen Version geleert, und die Placeholder kosten O(1). diamond-types hält bei C1/C2 offenbar einen großen Zustand. Das haben wir nicht im Detail untersucht. Es ist eine Beobachtung, keine Erklärung.
- Bei „Zuverlässigkeit“ lassen sich zwei Implementierungen schlecht per Zahl vergleichen. Wir können aber belegen, was *unsere* Implementierung absichert: Orakel-Fuzzing, Invarianten nach jedem Schritt, ASan, Mutation Testing. Dazu kommt, dass Swift sicher kompiliert: Bounds-Checks und Overflow-Checks bleiben im Release-Build *an*. Wir verzichten bewusst auf `-Ounchecked`.
- Die Messung lief auf x86-Linux. Auf Apple Silicon kann das Verhältnis anders aussehen. Das ist die erste Sache, die du auf deinem Mac nachmessen solltest.

---

## 8. Wo Rust (noch) vorne liegt, und nächste Schritte

- **A1/A2 (stark verzweigte Historien):** Der Rest-Rückstand steckt in Retreat/Advance, also in `addToCur` mit `find`, Splits, Propagation und Merges. Ideen: (1) die Parent-Slot-Position pro Knoten speichern statt sie zu suchen, (2) Spans auf 20 Byte verdichten (Int32-LVs statt Int), damit doppelt so viele pro Cache-Line passen, (3) ein echtes Kostenmodell statt der Schwelle von 64 Entries für die DFS-Reihenfolge.
- **Speicher A2:** `leafOf` und `delTarget` sind dichte Arrays über alle getrackten Events (je 4 Byte). Eine RLE-Variante, wie sie diamond-types nutzt, würde A2 unter Rust bringen.
- **Inkrementeller Merge mit Fast-Forward:** `TextDocument.merge` trackt derzeit jedes neue Event. Für den häufigsten Fall (Remote-Events ohne Nebenläufigkeit) könnte es direkt vorspulen.
- **Mutation Testing mit Schemata:** Statt eines Rebuilds pro Mutant alle Mutanten einmal hinter einem Laufzeit-Switch kompilieren (wie swift-mutation-testing). Das wäre etwa 10× schneller.
- **Persistenz und Netzwerk:** ein kompaktes Binärformat fürs Oplog (diamond-types' `.dt` lesen und schreiben) und ein Sync-Protokoll (Version-Summaries austauschen).
- **API für Apps:** Cursor-Positionen über Merges hinweg transformieren und eine SwiftUI/TCA-Anbindung.

---

## Glossar

- **LV (Local Version):** lokale fortlaufende Event-Nummer, eine topologische Sortierung.
- **Frontier:** Menge der jüngsten Events einer Version.
- **NYI:** „not yet inserted“, ein Item, das bei der aktuellen Tracker-Version noch nicht existiert.
- **Kritische Version:** Punkt in der Geschichte, an dem nichts parallel läuft.
- **Retreat/Advance:** Den Tracker-Zustand rückwärts oder vorwärts über Events bewegen.
- **Equivalent Mutant:** Eine Mutation, die das Verhalten nicht ändert und deshalb von keinem Test getötet werden kann.
