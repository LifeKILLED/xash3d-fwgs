# RGB light cache и seed replay

Активные проходы: lc_gbuffer_clear, lc_gbuffer_raster,
lc_update_point, lc_update_polygon,
primary/G-buffer, lc_reflection и lc_bounce, существующие denoiser/compositor.
Старые reflection prepare/claim исключены из rt.json: новые проходы сами
вычисляют адрес истории. Legacy исходники сохранены отдельно.

## Входные данные и LM UV

* `ray_interop.h`: `UniformBuffer`, `PointLight`, `PolygonLight`, `LightsMetadata`,
  `ModelHeader`, `Kusok`, `Vertex`, маски TLAS; структуры должны совпадать на CPU/GPU.
* CPU-подготовка probes и прежний geometry SSBO удалены. `UniformBuffer.lightcache_init_frame`
  хранит номер кадра последней инициализации LM G-buffer. При загрузке карты,
  перезагрузке графа или пересоздании изображений CPU назначает текущий кадр
  кадром инициализации. GPU строит G-buffer только при равенстве
  lightcache_init_frame и frame_counter; номер сохраняется как поколение кэша.
* `lc_gbuffer_clear/raster.comp` работают только в кадре инициализации.
  Clear обнуляет position/normal images. Raster читает `lc_brush_surfaces`,
  существующие index и vertex buffers; один invocation обрабатывает поверхность.
  В каждом texel восстанавливаются barycentrics и локальные position/geometry
  normal; точки вне треугольников прижимаются к ближайшей точке поверхности.
  Запись идёт прямо в `rgba32f image2D` через `imageStore`, без атомиков,
  owner-image и отдельного resolve-прохода. Диапазон записи включает только
  центры texels внутри LM-прямоугольника, без расширения на соседние острова.
* Вся подготовка CPU-данных находится в одной функции `R_BrushPrepareLightcache`
  в `vk_brush.c`. Она использует готовый список brush-моделей и их render geometry:
  при rebuild заполняет `lc_brush_surfaces` (vertex offset, index offset, count,
  стабильный brush ID), каждый кадр обновляет `lc_brush_transforms` (три строки
  affine transform на brush). Поверхности хранятся в RGBA32F image2D;
  матрицы — в отдельном std430 SSBO, по 48 байт на brush. Ёмкость буфера —
  MAX_MODELS (192 КиБ в текущей сборке), каждый кадр загружается только
  занятый диапазон. Матрицы пишутся прямо в существующий staging без CPU-копии
  всей таблицы. Создание и загрузка используют существующие resource/staging API;
  отдельная shutdown-функция только освобождает ресурсы. Внутри подготовки
  последовательно расположены регистрация ресурсов, перестроение и загрузка
  данных уровня, затем обновление матриц текущего кадра. Привязка brush к entity
  представлена одной структурой, состояния STATIC/UNBOUND имеют именованные константы.
* `Kusok`, `ModelHeader` (96 байт), код загрузки и обработки instances не изменены.
  В UBO из новых данных остался только номер кадра `lightcache_init_frame`.
* Привязка brush к entity сохраняется на CPU; матрицы обновляются независимо
  от camera visibility/TLAS. Для мира используется identity, для origin patches —
  матрица переноса из patch. Поздние entity привязываются при появлении.
* `lightcacheSurface` читает brush ID из normal.w и напрямую получает три строки
  матрицы из SSBO по адресу brush_id * 3. Трансформация выполняется один раз
  на texel в каждом lighting pass,
  до перебора источников и shadow rays. Поиска instance и transform-pass нет.
* BSP: исходный `Vertex.lm_tc` поступает из того же пути построения lightmap UV,
  который использует обычный Vulkan renderer. `rayLightmapUV` интерполирует три
  `lm_tc` по barycentrics уже committed intersection. Повторного луча нет.
* Studio: `R_LightVecSurface` в `rlight.c` возвращает поверхность и локальную
  точку из ванильного поиска света для entity. `R_LightmapCoord` переводит эту
  точку в UV того же атласа. Поля `lightmap_uv` / `lightmap_uv_valid` проходят
  через model draw / instance в `ModelHeader`. Все submodels используют
  одну привязку entity; это ванильная привязка к освещающей BSP-поверхности,
  а не отдельная развёртка studio mesh. Sky/fullbright без LM-попадания не имеют UV.
* `rayLightmapUV` сначала проверяет studio binding в `ModelHeader`, затем BSP UV.
  UV остаются float; компонент z возвращаемого vec4 — признак валидности.
  Нельзя восстанавливать UV из screen coordinates, округлять их до lookup или
  заменять studio binding новым поиском поверхности.

## Обновление и представление

Логический LM-атлас — 512×512 (половина исходного 1024×1024).
Нормализованные LM UV не меняются: texel = ivec2(uv * 512).
Изображения используют существующее backing allocation графа (минимум 1280×800),
но кэш занимает только область 512×512. Циклы в compute покрывают весь атлас
даже при viewport меньше 512. Экранное разрешение не меняет адрес кэша.

Два G-buffer images `lc_local_position/normal` хранят локальную геометрию.
Position.w содержит surface ID + 1 (ноль — пусто), normal.w — стабильный brush ID.
Оба G-buffer images объявлены в шейдерах и автоматически создаются существующим
графом через `out_`; формат RGBA32F. `lc_brush_surfaces/transforms` — внешние
CPU-входы графа, подготовка которых локализована в `R_BrushPrepareLightcache`.
Изменений `sebastian.py` не требуется. Lookup buffer, owner-image,
world-position/normal images и плотная упаковка probes не используются.
Bilinear фильтр принимает только texels того же владельца; bilinear
веса оставшихся texels нормализуются. Материал и камера не участвуют в обновлении.

## Обновление cache

Point и polygon перебирают все источники legacy light cluster по мировой
позиции probe. Видимость и вклад рассчитываются по направлению к центру источника;
для polygon используется центр площади, для environment — ось источника.
Случайного выбора точки на источнике нет.
При нулевом вкладе visibility ray не запускается. RIS-вариант удалён.
RGB cache хранит unit-albedo outgoing diffuse radiance (E/pi), без SH.
Отдельного прохода фильтрации и темпорального смешивания нет. Bounce, reflection
и debug читают готовую сумму из lc_radiance с bilinear интерполяцией в пределах island.
Первый update-проход записывает lc_point; второй добавляет к нему polygon-вклад
и записывает lc_radiance. Отдельного прохода суммирования нет.
Light cache использует постоянные текстуры lc_point/lc_radiance, без истории
и ping-pong. При отключении обновления update-проходы не перезаписывают текстуры;
в кадре инициализации отключённый cache обнуляется.

## Пути и история

Один новый кандидат за кадр, seed 0..8388607 точно хранится в float32.
Bounce получает мировые равномерные сферические направления из seed и номера
отскока, переворачивает знак по geometry normal. Tangent frame отсутствует.
Количество отскоков задаёт rt_bounces; выход при throughput <=0.001.
Reflection деформирует мировой вектор под изотропный GGX NDF по shading normal,
roughness и view; сохраняется корректный PDF отражения. Отступ луча 0.01.
Оба прохода читают освещение попаданий только из RGB cache.

История проецируется из geometry_prev_position. Проверяются границы, stamp,
валидность состояния и предыдущая плоскость с допуском 0.1 мировых единиц.
Для bounce также должно совпадать количество отскоков.
Случайный restart — 1/200. MAG (временно отключён) сравнивает центр и четыре осевых соседа:
при совпадении адресов reset с вероятностью 0.25; для выживших независимо
с вероятностью 0.25 выбирается сосед 3x3 вокруг history source без центра.
Radiance confidence линейный: 1 при отношении яркостей 1, 0 при <=1/1.5
или >=1.5. История принимается с вероятностью confidence.
Reflection дополнительно использует confidence длины первого луча с пределом
1.1, умноженный на radiance confidence; для зеркальных поверхностей работает
parallax reprojection с проверкой отражённого попадания и совпадения normals.
Отбраковки истории по roughness нет.

Путь истории повторяется из seed, sum := sum - old_target + new_target,
M не увеличивается при replay. Затем добавляется свежий кандидат.
Cap масштабирует sum и M вместе, нормализация W = sum/(M*target).
Параметры проверок находятся в bounce_path_config.glsl;
предел длины reflection — в reflection_path_config.glsl.
Тестовые cvar и диагностические режимы удалены. rt_disable_reprojection
управляет ASVGF и не выключает историю путей или cache.

## Выходы и проверка

Reflection: indirect_specular и reflection_direction_pdf (ray segment, PDF),
далее spatial reconstruction. Bounce: суммарный RGB с throughput и первое
направление в верхней левой четверти; остальные четверти нулевые.
Далее существующий SH denoiser восстанавливает освещение по shading normal.
SH в cache не используется.

Порядок rt.json существенен: cache filter и primary должны предшествовать
lc_reflection/lc_bounce, затем идут spatial reconstruction и SH denoising.
Проверки: python waf build; python ref/vk/tests/lc_gbuffer.py;
python ref/vk/tests/lc_path_reservoir.py;
spirv-val --target-env vulkan1.2 для SPIR-V новых проходов.

## Эксперимент: permutation sampling

LC_PATH_PERMUTATION_SAMPLING=1 и LC_PATH_MAG_DEDUPLICATION=0
в bounce_path_config.glsl управляют обоими новыми проходами.
После обычной репроекции (и parallax у reflection) адрес истории переставляется
по формуле ((pixel + offset) XOR 3) - offset отдельно по X/Y.
Offset 0..3 общий для всех текселей прохода, меняется по frame counter и UBO
random seed; bounce и reflection используют разные соли. Bounce переставляет
адреса внутри своей четверти, reflection — в полном разрешении.
На границе пара, выходящая за изображение, остаётся на месте: нет clamp
и повторного использования одного граничного адреса разными парами.
Проверки плоскости, radiance, длины reflection и restart остаются и читают
данные окончательного донора. Путь повторяется из seed на текущей поверхности;
готовые соседние цвета не смешиваются. История экранного денойзера не
переставляется. Эксперимент проверяется в игре пользователем.

Для reflection при roughness > 0.5 пределы confidence плавно расширяются
через smoothstep: radiance ratio 1.5 -> 3.0, length ratio 1.1 -> 2.0
к roughness=0.6; выше 0.6 остаётся полное смягчение. При roughness <=0.5 поведение прежнее. Переход hit/miss
по-прежнему обнуляет length confidence; первичная plane-проверка не ослаблена.
Макросы REFLECTION_PATH_RELAX_ROUGHNESS_START/END,
REFLECTION_PATH_ROUGH_RADIANCE_RATIO, REFLECTION_PATH_ROUGH_LENGTH_RATIO
заданы в reflection_path_config.glsl. Replay после перестановки восстанавливает
мировой D из seed и меняет его угол по GGX, без tangent frame.

Reflection permutation дополнительно ограничена зеркальным направлением.
При roughness=0 перестановка запрещена; на (0,0.5] требуется dot текущего
reflect(-V,N) и зеркального направления донора предыдущего кадра не меньше
линейного порога 1 -> 0.95. При roughness>0.5 эта проверка отключена.
Используются shading normals и view из соответствующих кадров. Порог 0.95
задан REFLECTION_PATH_PERMUTATION_HALF_ROUGHNESS_DOT. При отказе сохраняется
исходный ordinary/parallax source; резервуар из-за этого gate не сбрасывается.
Остальные проверки финального донора продолжают работать.
