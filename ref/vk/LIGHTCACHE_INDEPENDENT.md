# Независимый RGB light cache

Семь переносимых файлов: этот документ, `lc_independent.glsl`,
`lc_update_point.comp`, `lc_update_polygon.comp`, `lc_filter.comp`,
`lc_reflection.comp`, `lc_bounce.comp` (шейдеры находятся в `shaders/`).
В `rt.json` включены новые проходы вместо старых lightcache, compound bounce
и reflection; существующие reflection prepare/claim сохранены для репроекции. Старые исходники сохранены. Point, polygon, reflection и многошаговый diffuse bounce выполняются отдельными dispatch.
Первый и все последующие bounce лучи используют исключительно geometry normal;
shading normal применяется только в SH projection после экранного denoising.

## Диагностика репроекции без отбраковки

`rt_path_reprojection_no_rejection 1` (временно включён по умолчанию) передаётся
через `RENDERER_FLAG_PATH_REPROJECTION_NO_REJECTION`. Для reflection/bounce
используется прямая проекция previous world position, без parallax-поиска,
перестановки доноров, depth/plane/normal/roughness reject, MAG, случайного restart,
firefly/relight reject и понижения transport confidence. Сами трассировки,
переоценка target и формула merge не меняются. Остаются bounds/active primary,
frame stamps, числовая валидность metadata и reservoir, совместимость bounce count;
ограничение максимального M уменьшает mass и M вместе, не меняя W.
ASVGF и light cache этой опцией не меняются. Переключение сбрасывает историю один
раз для чистого сравнения. `rt_path_reprojection_no_rejection 0` возвращает все
сохранённые рабочие механизмы (включая MAG replacement 3x3). Описанные ниже
поведенческие проверки относятся к обычному режиму 0.

## Входные данные и LM UV

* `ray_interop.h`: `UniformBuffer`, `PointLight`, `PolygonLight`, `LightsMetadata`,
  `ModelHeader`, `Kusok`, `Vertex`, маски TLAS; структуры должны совпадать на CPU/GPU.
* `lightcache_geometry.glsl` / `lightcache_layout.h` / `vk_lightcache.c`: SSBO
  `lightcache_geometry` — info (число probes, epoch), lookup 1024×1024,
  transforms[512] и плотно упакованные `LightcacheProbe`. На probe нужны локальная
  позиция, geometry normal, индекс brush transform, island, начало/размер сетки,
  локальный индекс и прямоугольник исходного LM-атласа.
* CPU создаёт probes при выделении BSP lightmap через `RT_LightCacheAddSurface`.
  Шаг — два исходных LM-текселя, размер острова `ceil(width/2) × ceil(height/2)`.
  Последняя позиция при нечётном размере прижата к последнему исходному текселю.
  Позиции ограничены BSP-полигоном. Трансформы brush обновляются каждый кадр.
* BSP: исходный `Vertex.lm_tc` поступает из того же пути построения lightmap UV,
  который использует обычный Vulkan renderer. `rayLightmapUV` интерполирует три
  `lm_tc` по barycentrics уже committed intersection. Повторного луча нет.
* Studio: `R_LightVecSurface` в `rlight.c` возвращает поверхность и локальную
  точку из ванильного поиска света для entity. `R_LightmapCoord` переводит эту
  точку в UV того же атласа. Поля `lightmap_uv` / `lightmap_uv_valid` проходят
  через model draw / instance в 96-байтный `ModelHeader`. Все submodels используют
  одну привязку entity; это ванильная привязка к освещающей BSP-поверхности,
  а не отдельная развёртка studio mesh. Sky/fullbright без LM-попадания не имеют UV.
* `rayLightmapUV` сначала проверяет studio binding в `ModelHeader`, затем BSP UV.
  UV остаются float; компонент z возвращаемого vec4 — признак валидности.
  Нельзя восстанавливать UV из screen coordinates, округлять их до lookup или
  заменять studio binding новым поиском поверхности.

## Обновление и представление

Все storage images имеют размер viewport; probe `i` хранится в
`(i % res.x, i / res.x)`. Lookup возвращает `i+1`, ноль означает отсутствие
привязки. Обязательно проверять capacity; недостающие probes не алиасить.
Материалы и направление камеры не участвуют в обновлении.

`lc_update_point` и `lc_update_polygon` используют TLAS, textures, геометрию и актуальный `LightsMetadata`.
`rt_lightcache_bruteforce 0` (по умолчанию) выбирает RIS: восемь дешёвых
предложений ID, один выбранный shading sample на probe для каждого типа света.
`rt_lightcache_bruteforce 1` включает полный перебор point/polygon ID из
`light_grid` по world-space позиции probe, как в legacy lighting. Один concrete
sample берётся для каждого источника и суммируется без RIS-нормализации.
Кластер вычисляется как `floor(P / LIGHT_GRID_CELL_SIZE) - grid_min_cell`;
проверяются обе границы сетки, capacity и ID. Вне grid вклад нулевой, глобального
fallback нет. Полнота источников соответствует кластерному списку legacy.

Опция передаётся битом `RENDERER_FLAG_LIGHTCACHE_BRUTEFORCE` в `renderer_flags`.
Обычный uniform `if` в обоих шейдерах выбирает ветку для всех текселей; отдельных
pipelines и вариантов компиляции нет. Выходные RGB и последующая фильтрация общие.
Смена режима инвалидирует cache history и помечает temporal discontinuity.

Случайные координаты concrete shadow/light sample стабильны: seed зависит только
от адреса исходного LM-текселя (`lm_s/lm_t + 2 * island-local coordinates`), ID
и типа источника. Кадр, `random_seed`, экранная упаковка cache, resolution и
brush world transform не входят в seed. RIS и bruteforce для той же пары дают
те же координаты семпла на источнике. Выбор ID/merge RIS остаётся случайным по
кадрам; фиксируется точка на выбранном источнике, а не RIS-последовательность.

Ниже описан RIS-режим. Для каждого типа восемь равномерных предложений light ID проходят через RIS
с дешёвым положительным target. Выбранный источник семплируется один раз:
point/environment — по телесному углу, polygon — по площади треугольного веера.
Учитываются spot attenuation, ориентация polygon и shadow ray с alpha test.
Environment использует общую проверку sky visibility. В новых файлах нет ReGIR,
LTC, visibility reuse или старого RIS-кодирования.

`lcDiffuse` вычисляет `Li * max(dot(geometry_normal,L),0) / pi`.
Выходы `lc_point` и `lc_polygon` — линейная RGB radiance единичного Lambert
receiver без albedo, view, specular и SH; cosine уже включён, повторно применять
его при чтении нельзя. Нормализация RIS: `sum / (count * selected_target)`;
нулевые предложения учитываются в count. Общий инклуд содержит только
резервуар, функции весов и этот diffuse shading.

`lc_filter` суммирует point/poly, усредняет доступные 3×3 taps одного island с
одинаковым весом и смешивает 10% результата с 90% предыдущей RGB radiance.
На краю делитель равен числу доступных taps; чужие islands не читаются.
Чтение и запись — разные ping-pong images. История валидна только при совпадении
epoch, resolution и последовательных кадров. Freeze (`rt_disable_lightcache_update`)
сохраняет только валидную историю; вне capacity записывается ноль.

## Reflection и bounce

`lc_reflection` выполняет трассировку, читает cache и сразу записывает финальный
цвет отражения. Резервуар содержит целый путь: выбранную GGX random pair,
её target, сумму весов и эффективное число семплов. Каждый кадр строится свежий
путь; historical random pair переигрывается на текущей геометрии и текущем RGB
cache. Существующие `reflection_path_prepare` / `reflection_path_claim` выбирают
primary-plane history, проверяют frame stamp, roughness и geometry normal,
удаляют локальные копии и выполняют независимый restart. Shading normal delta
между кадрами больше не является hard reject. Motion и
изменение secondary hit ограничивают confidence с сохранением нормализации.
GGX NDF sampling использует тот же alpha=roughness² (alpha²=roughness⁴), что
и BRDF, включая floor 1e-5 из ggxD; PDF учитывает half-vector Jacobian. Roughness < 0.004
считается зеркалом. Target ограничен 1e-6..1.3, confidence — 640 (при движении
снижается, как в исходном reflection), финальная luminance — 1.3.

`REFLECTION_PATH_VALIDATE_SAVED_FRAME=1` разделяет confidence validation и shading.
В `temporal_lc_reflection_view` сохраняется точный view vector выбранного семпла;
normal frame сохраняется в `temporal_reflection_path_normals`. Историческая pair
проверяется в сохранённых shading normal/view/roughness, а не в новой случайно
изменившейся normal-map выборке. Если frame изменился, дополнительный visibility
ray из текущей primary поверхности проверяет этот старый отскок на текущей
геометрии; для сравнения с historical hit secondary точка переводится в previous
world coordinates через vertex/model motion. Этот ray не вычисляет свет.
Статичный совпадающий frame использует уже выполненную трассировку.

Сам historical contribution, target, PDF, итоговый ray segment и выбранные
выходные данные по-прежнему пересчитываются по текущим normal/view и текущему
cache. Поэтому не используется старое освещение или PDF от другой normal.
В конце кадра сохраняется текущий frame выбранной pair для следующей проверки.
Geometry normal/depth/disocclusion, hemisphere, roughness, ownership, restart и
anti-firefly проверки сохраняются. Дополнительного visibility ray нет для уже
подтверждённого parallax reuse. В bounce такого normal-map hard reject не было:
весь diffuse transport использует geometry normals.

При неподвижном camera origin confidence не уменьшается от расстояния между
текущим и history pix: экранный сдвиг от вращения камеры не является world-space
изменением view в той же точке. Translation confidence вычисляется только по
расстоянию между camera origins относительно глубины primary точки. Проверка
реального transport change в сохранённом frame остаётся.

Если origins совпадают с допуском `REFLECTION_PATH_PARALLAX_TRANSLATION_EPSILON`
(0.001 world units), reflection оставляет ровно адрес прямой проекции: отдельный
2x2 parallax поиск не меняет донора в этом случае.

Средний интервал независимого restart reflection увеличен с 128 до 1280 кадров,
static/moving confidence caps — с 64/4 до 640/40. У bounce нет принудительного
возрастного сброса (`MAX_HISTORY_AGE=0`); cap эффективных семплов увеличен
с 256 до 2560. Cap и случайный срок жизни — разные параметры; геометрическая
невалидность по-прежнему запрещает reuse.

Для зеркала (`roughness < 0.004`) при `dot(shading_normal,geometry_normal) >= 0.98`
разрешена parallax reprojection резервуара. Текущее committed reflection hit
переносится в предыдущий кадр через `Vertex.prev_pos` и `ModelHeader.prev_transform`,
отражается относительно предыдущей mirror plane и проецируется предыдущей камерой.
Из 2x2 footprint выбирается только historical hit с тем же instance/geometry/triangle
и близким previous-world положением (допуск `max(0.05, secondary_distance*0.002)`).
Historical mirror также должен иметь roughness < 0.004, dot нормалей >= 0.98,
валидную глубину на той же плоскости, frame stamp и reservoir. Нормаль mirror plane
между кадрами должна совпадать до dot >= 0.999: для вращающихся/кривых зеркал
остаётся обычная primary-plane репроекция. Miss, disocclusion, другое отражённое
попадание и неподходящие normals не допускают parallax reuse. Принятый parallax
sample сохраняет полный confidence cap: ожидаемый сдвиг по экрану не штрафуется.
Дополнительное history image `temporal_lc_reflection_hit_identity` хранит ID
реального выбранного reflection hit, подтверждая его видимость в прошлом кадре.

`lc_bounce` выполняет весь diffuse путь в одном dispatch: цикл из
`rt_bounces` отскоков (по умолчанию 3). Число передаётся через новое поле
`UniformBuffer.bounce_count` из `vk_rtx.c`, независимо от размера atlas.
`rt_bounces 0` даёт нулевой GI, отрицательные значения считаются нулём;
изменение настройки сбрасывает temporal history. Программного лимита четыре нет. В каждой вершине
читает cache, умножает throughput на albedo и diffuse fraction поверхности,
добавляет `throughput * cachedIrradiance`, затем продолжает cosine hemisphere
лучом вокруг geometry normal. Промах завершает путь; отсутствующие LM UV дают
нулевой локальный вклад, но не мешают продолжению. Primary albedo остаётся для
compositor. Cache хранит E/pi (единичную Lambert radiance), поэтому при чтении
его как irradiance для diffuse transport повторного деления на pi нет.

Bounce тоже сохраняет резервуар целого пути, а не результат смешивания RGB.
`temporal_lc_bounce_path` хранит seed (две точные 16-битные части), число отскоков
и frame stamp; `temporal_lc_bounce_reservoir` — target, sum, M, W;
Существующая
`temporal_reprojection_bounce_source` задаёт history donor, включая текущую
парную перестановку. Проверяются границы, frame, число отскоков и валидность reservoir metadata.
Поверхности донора не сравниваются: geometry/shading normals, depth/plane и
material не отбраковывают bounce history. `TEMPORAL_BOUNCE_SKIP_SURFACE_CHECKS=1`
в подготовке/resolve карт задаёт обычную проекцию previous world position
именно для `pix*2`, без выбора другой поверхности из 2x2. Парная перестановка
также не требует совместимости плоскостей.

Для bounce вместо прежнего 5x5 owner/reject теста используется 5-tap MAG rejection
в `temporal_reprojection_claim.comp`: центр, верх, низ, лево, право. Сравниваются
только history coordinates исходной карты репроекции до парной перестановки,
переведённые в half-resolution reservoir texels. Если хотя бы один осевой сосед
ссылается на тот же source, с вероятностью 1/4 история центра заменяется
случайным history texel из 3x3 вокруг окончательного адреса репроекции, исключая
центральный. Это одна попытка на центр независимо от числа дубликатов, без выбора
владельца и без сравнения поверхностей, яркости или seed. За границей соседи пропускаются,
а не clamped на центр. Макросы `TEMPORAL_BOUNCE_MAG_REJECTION=1` и
`TEMPORAL_BOUNCE_MAG_REJECT_PROBABILITY=0.25` задают эксперимент. Direct RIS
сохраняет прежний owner/reject механизм. Для bounce claim сохраняет ready=1
и передаёт replacement marker через ready.B и resolved source.B. После обычной
перестановки donor выбирается 3x3 neighbor вокруг полученного history source.
Выбор не проверяется повторно на дупликацию. Веса/M и seed целиком загружаются
из нового адреса; обычные frame/metadata/relight проверки остаются.

Reflection использует такой же 5-tap тест адресов history texels в
`reflection_path_claim.comp`, до трассировки. Макросы в
`reflection_path_config.glsl`: `REFLECTION_PATH_MAG_REJECTION=1`,
`REFLECTION_PATH_MAG_REJECT_PROBABILITY=0.25`. Fractional owner key в source.x
отбрасывается перед сравнением координат. При включённом MAG старый
детерминированный owner-тест reflection не применяется дополнительно; он
остаётся доступен при `REFLECTION_PATH_MAG_REJECTION=0`. Соседи за границей
не считаются копиями центра. Одна попытка 1/4 независимо от числа совпадений.
Для reflection ready.G отмечает замену; 3x3 neighbor выбирается уже после
parallax lookup вокруг окончательного history texel, не вокруг текущего pix.
При замене parallax confidence shortcut отключён: новый сосед не был подтверждён
parallax-проверкой. Random pair, reservoir, frame normal/view, hit и luminance
берутся из одного нового адреса. Common helper `temporalHistoryNeighbor3x3Index`
выбирает только in-bounds соседей (на краю подмножество из восьми), не clamped
центр. Исключение — вырожденное изображение 1x1, где соседей вообще нет.
Макросы с суффиксом REJECT_PROBABILITY теперь задают вероятность такой замены,
а не сброса. Ни повторного duplicate-теста, ни поиска самого старого M нет.
Seed однозначно задаёт случайные размеры всего пути независимо от текущих
pixel/frame. Исторический путь полностью переигрывается от текущей primary
поверхности: все сегменты заново проверяют видимость и читают текущий cache.
Это заменяет хранение четырёх вершин старого atlas и round-robin проверку одного
сегмента; стоимость replay растёт с `rt_bounces`, зато лимита atlas нет.

Общий `lcMergePath` объединяет свежий и historical path по полному вкладу:
`history_mass = old_sum * min(old_M, cap) / old_M * new_target / old_target`.
Сохраняется выбранный seed/random pair и соответствующее первое направление,
а цвет выводится с `sum / (M * selected_target)`. Cap уменьшает sum и M вместе.
Для bounce используются настройки confidence (2560) и output weight
(32) из `bounce_path_config.glsl`. Нулевые пути остаются в распределении с target
1e-6. Флаг отключения reservoir reuse даёт только свежий путь.
`rt_disable_reprojection` управляет только ASVGF: path reservoirs, подготовка
карт репроекции и temporal light cache продолжают работать при значении 1.
Bounce path histories, как и его цвет, занимают лишь первую четверть; остальные
четверти очищаются. Резервуаров выбора источников света в secondary проходах нет.

Отдельный от медианного firefly filter эксперимент — relight confidence для
reflection и bounce. `LC_PATH_RELIGHT_REJECTION=1`, `LC_PATH_RELIGHT_MAX_RATIO=4.0`,
`LC_PATH_RELIGHT_LUMINANCE_FLOOR=1e-6` в `lc_independent.glsl`. Сравнивается
luminance одной и той же выбранной pair/seed до умножения на RIS weight W:
сохранённый вклад и переоценённый текущий вклад. Если отношение большего к меньшему
(с floor) больше 4, historical path полностью пропускается до merge, включая
его mass и M. При отказе остаётся свежий резервуар, без наследования старого W.
Невалидные/нечисловые вклады также пропускаются. Это эвристика: сильное настоящее
изменение освещения/пути тоже сбросит историю. Она не проверяет соседние поверхности.

Для этого в обоих `temporal_lc_*_luminance` хранится R = normalized estimator,
G = raw selected-path luminance, B = frame stamp. Reflection view history также
хранит frame stamp в W. Проверка stamp не даёт объединить sample/frame и radiance
из разных кадров; добавленный формат автоматически начинает со свежей истории.
Сравнивать новый raw вклад с прежним R (цветом после W) нельзя: это создавало бы
ложные resets от изменения самого веса резервуара.

Экспериментальный anti-firefly gate при репроекции задан макросами в
`lc_independent.glsl`: `LC_PATH_FIREFLY_REJECTION=0` (сейчас выключен), `LC_PATH_FIREFLY_RATIO=1.5`,
`LC_PATH_FIREFLY_KILL_PROBABILITY=0.25`, `LC_PATH_FIREFLY_MIN_SAMPLES=8`. Для фактического history source (после
parallax выбора у reflection) читаются четыре осевых соседа left/right/up/down
в предыдущем изображении luminance. Медиана — среднее двух центральных значений.
Если эффективное число семплов source резервуара M строго больше 8 и его luminance
строго больше медианы ×1.5, с вероятностью 0.25 история
не участвует в merge; остаётся свежий путь. Никаких depth/normal/material gates
для соседей нет. На границе координаты clamped; bounce ограничен своей четвертью.
Для luminance есть отдельные `temporal_lc_reflection_luminance` и
`temporal_lc_bounce_luminance`: они хранят luminance полного estimator с RIS
нормализацией в R (G/B используются relight confidence, описанным выше). Возраст для gate берётся из существующего reservoir M
(один свежий кандидат на кадр), отдельного счётчика возраста нет.
Luminance хранится до final luminance/output-weight clamps, чтобы clamp не скрывал
светляк. RNG отбрасывания независим от RNG пути и света. Макрос 0 выключает gate.

Committed hit даёт LM UV через общий `rayLightmapUV`; четыре cache taps читаются
в координатах island с существующей обработкой короткого крайнего интервала.
Интерполируется RGB, результат ограничивается снизу нулём. Цвет вторичной
поверхности и её diffuse fraction применяются при чтении. Нет point/poly
lighting на secondary hit, SH-проекции, sky/emissive добавки или fallback.
Промах и отсутствующие UV не добавляют свет. Legacy translucent compositing
в этой компактной версии отсутствует.

Контракт существующих denoiser сохранён:

* Reflection: `indirect_specular` (RGBA16F, финальный RGB) и
  `reflection_direction_pdf` (RGBA32F, xyz = выбранный ray segment с длиной,
  w = proposal PDF), полное разрешение. Первый потребитель —
  `spatial_reconstruction_pass1`, далее существующая цепочка specular denoising.
* Bounce: `indirect_diffuse` (RGBA16F, суммарный RGB всех отскоков) и
  `first_bounce_direction` (RGBA32F, xyz = направление первого луча).
  Результат лежит в блоке `res/2` слева сверху; primary читается по `pix*2`.
  Первый потребитель — `diffuse_gi_sh_denoise_init`, который расширяет sample
  в 2×2 и начинает существующую SH-цепочку. Остальная часть images очищается.

`rt_disable_gi` и `rt_disable_reflection` выключают свои проходы с записью нулей.
Режим separated reflection сохраняет соглашение compositor о восстановлении цвета.
SH появляется только внутри существующего экранного GI denoiser, а light cache
и оба новых прохода хранят и передают RGB. Отдельных point/poly lighting и resolve
проходов для reflection/bounce нет.

## Подключение и проверка при переносе

Порядок в `rt.json` существенен: `VMeatpipe` выполняет dispatch последовательно,
а не сортирует зависимости. Cache update/filter могут идти до primary, но
`primary_ray → temporal_reprojection_prepare/claim/resolve` обязаны предшествовать
`reflection_path_prepare/claim → lc_reflection` и `lc_bounce`. Далее идут
spatial reconstruction и SH init/filter/save, затем final precombine и denoiser.
Нарушение этого порядка давало пустой INDIRECT_DIFF из-за чтения неготовых
G-buffer/reprojection maps; throughput уже включён в RGB bounce и отдельного
буфера для объединения отскоков не требуется.
Граф должен распознавать `out_`, `temporal_`, `prev_temporal_` и создавать barriers
и ping-pong. Сохраняются внешние SSBO geometry и общие TLAS/model buffers.
В текущем `lightcache_reservoir_sampling.glsl` старый код временно выключен:
экранный direct/refraction RIS получает пустой seed и использует свои proposals.
Переносить новый RGB cache в старый формат RIS-резервуаров нельзя.

`LIGHT_CACHE` показывает сырые point+polygon radiance; `DIRECT_DIFFUSE_CACHE` —
temporal RGB с четырьмя taps. Для возврата старого варианта восстановить список
проходов `rt.json`, debug-чтение `denoiser.comp` и старое RIS seeding.

Проверки: `python waf build`; `spirv-val --target-env vulkan1.2` для новых SPIR-V
и reflection prepare/claim. `python ref/vk/tests/lc_path_reservoir.py` компилирует
реальные GLSL helpers как C++ и перебирает варианты temporal selection: смену
освещения, нулевые пути, caps до 2560, сохранение нормализации, точную упаковку seed и порог mirror normals.
Тест также проверяет порядок producer/consumer проходов в реальном `rt.json`,
сохранение нормализации при перестановке history адресов с неподвижным origin,
energy bound белого GGX при normal incidence и rejection dark-to-bright history
до роста её mass. Проверены граничные значения relight ratio и нечисловые данные.
В игре проверить studio на освещённом полу, вращающийся brush, islands 1×1 и с
нечётными размерами, reload карты, смену resolution и freeze/unfreeze. Отдельно
проверить spot/environment, polygon backface и alpha-masked occluders.

## Новый bounce: мировой seed replay

Bounce использует один новый кандидат за кадр. Seed — целое 0..8388607,
точно представимое в float32 (все целые до 16777216 представимы точно).
Metadata теперь содержит seed в X, 0 в Y, bounce count в Z, stamp в W.
Для каждого номера отскока seed задаёт равномерную мировую сферу; направление
умножается на -1 при отрицательном dot с geometry normal. Tangent frame
и cosine sampling не используются. Отступ origin равен geometry normal * 0.01,
остановка по максимальной компоненте throughput <= 0.001.
История берётся прямой проекцией geometry_prev_position, без MAG, перестановок,
проверок поверхностей, длин и radiance confidence. Остаются границы изображения,
stamp, совместимость числа отскоков и числовая валидность состояния.
Путь истории переигрывается, sum := sum - old_target + new_target, M сохраняется.
Затем обычным reservoir offer добавляется один свежий кандидат. Cap масштабирует
sum и M вместе. Диагностические transport/unit-weight/reuse переключатели
больше не изменяют этот bounce. Reflection не изменён этим переходом.

Bounce MAG: сравниваются адреса прямой репроекции центра и четырёх осевых
соседей. При совпадении история сбрасывается с вероятностью 0.25. Для выживших
дубликатов независимо с вероятностью 0.25 выбирается случайный сосед 3x3
вокруг history source, исключая центр. Проверка плоскости применяется к итоговому
источнику. Вероятности: BOUNCE_PATH_MAG_RESET_PROBABILITY и
BOUNCE_PATH_MAG_REPLACEMENT_PROBABILITY.
Radiance confidence сравнивает target replay с сохранённым raw target до W:
линейно от 1 при отношении 1 до 0 при 1/1.5 и 1.5, за пределами — 0.
История принимается с вероятностью confidence, иначе остаётся свежий кандидат.
Предел задаёт BOUNCE_PATH_RADIANCE_RATIO. Сброс 1/200 также сохраняется.

Reflection теперь использует тот же принцип seed replay и замены вклада истории,
что и bounce. Metadata: X = точный seed 0..8388607, Y = format tag 2,
Z = roughness (без отбраковки по ней), W = frame stamp. Старые random-pair
истории не принимаются. Мировой сферический вектор переворачивается по shading
normal, затем его угол деформируется под изотропный GGX NDF. Tangent frame
не строится; PDF сохраняет half-vector Jacobian. Зеркальный предел <0.004
сохранён. Геометрическая нормаль задаёт отступ и допустимость исходящего луча.
Проверки истории повторяют bounce: предыдущая плоскость, restart 1/200,
MAG reset/replacement 0.25, мягкий radiance confidence с границами 1/1.5..1.5.
Parallax, roughness rejection, saved-frame/camera/hit confidence и старые
prepare/claim maps больше не используются lc_reflection. Настройки проверок
общие с bounce в bounce_path_config.glsl. Контракт spatial reconstruction
(цвет, сегмент луча, PDF) сохранён.
