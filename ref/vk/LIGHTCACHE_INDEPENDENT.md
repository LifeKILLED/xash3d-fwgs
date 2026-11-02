# RGB light cache и seed replay

Активные проходы: lc_update_point, lc_update_polygon, lc_filter,
primary/G-buffer, lc_reflection и lc_bounce, существующие denoiser/compositor.
Старые reflection prepare/claim исключены из rt.json: новые проходы сами
вычисляют адрес истории. Legacy исходники сохранены отдельно.

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


## Обновление cache

Point и polygon перебирают все источники legacy light cluster по мировой
позиции probe. Для каждого источника берётся один конкретный sample;
его случайность стабильна по исходному LM texel и ID источника, без frame seed.
При нулевом вкладе visibility ray не запускается. RIS-вариант удалён.
RGB cache хранит unit-albedo outgoing diffuse radiance (E/pi), без SH.
Фильтр — равновесный box 3x3 в пределах island. Темпорального смешивания нет.
При отключении обновления сохраняется предыдущий cache.

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
Проверки: python waf build; python ref/vk/tests/lc_path_reservoir.py;
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
