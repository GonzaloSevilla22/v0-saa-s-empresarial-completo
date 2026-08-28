# v31-tenancy-role-assertion — Design

> **Retro-spec.** Este documento no diseña código: consolida el razonamiento de una redacción normativa sobre un comportamiento que ya está en `main` (`d7b5214`, PR #470, mergeado 2026-08-27 11:26:08 -0300) y ya corrió en producción. Las decisiones de acá son de **qué se escribe en la spec y cómo**, no de qué hace el sistema. La spec se escribe en abstracto; este archivo es el lugar donde viven los nombres reales, el detalle de implementación y la evidencia con fecha.

## Context

### El residuo D6 de `v31-tenancy-pool-rls`

El cluster de tenancy resolvió el aislamiento del camino de request del backend en dos pasos: el Paso 1 puso los claims y la conexión dentro de una transacción explícita por request, y el Paso 2 (D6) adoptó `authenticated` con `SET LOCAL ROLE` dentro de esa misma transacción, para que las policies —las 49 migraciones escritas para ese rol— se evaluaran también para el backend. La alternativa que **falla cerrado** —un rol de login dedicado, sin `BYPASSRLS` desde la conexión misma— se evaluó y se descartó como opción primaria:

> **Por qué NO un rol de login dedicado** (`app_request` con credenciales propias y cadena de conexión distinta). Es la opción que el brief del PO anticipaba y tiene una ventaja real —**falla cerrado**: si un camino de código olvidara el cambio de rol, con un rol de login restringido igual quedaría sin BYPASSRLS.
> — `openspec/changes/archive/2026-08-27-v31-tenancy-pool-rls/design.md:135`

Esa elección deja un trade-off explícito, registrado en la lista de riesgos de aquel change:

> **El cambio de rol por transacción falla abierto si un camino lo omite** → D6, trade-off explícito. Mitigado porque rol y claims se setean juntos, más una verificación que afirma el usuario efectivo desde dentro de un request. OQ-2 ofrece la alternativa que falla cerrado.
> — `design.md:195`

Y la mitigación que se declaró para él:

> **Mitigación del "falla abierto"** (el trade-off honesto de esta decisión): el cambio de rol y la inyección de claims ocurren **en el mismo lugar y en la misma transacción** — no pueden divergir sin que un test lo note. Se agrega una verificación que afirma, desde dentro de un request real, que el usuario efectivo de la sesión **no** es el rol con BYPASSRLS.
> — `design.md:137`

### Los dos modos del falla-abierto, y cuál caduca acá

D6 nombra un solo riesgo, pero contiene dos modos de falla distintos, con distinto mecanismo y distinto cierre. Conviene no confundirlos, porque este change cierra uno solo:

- **Modo *omisión*** — un camino de código **nunca emite** la adopción. Es literalmente lo que enuncia D6 ("si un camino lo omite"; `design.md:135` lo formula como "si un camino de código **olvidara** el cambio de rol"). **Sigue abierto por construcción**: la comprobación del PR #470 vive dentro de `get_db_conn`, así que un camino que no pase por ahí tampoco se comprueba. Su garantía estructural es el **Paso 3** —el rol de login sin `BYPASSRLS`—, resuelto por el PO en OQ-2 como trabajo **futuro** y explícitamente fuera del alcance de aquel change: *"El paso 3 no forma parte del alcance ni de las tareas de este change; se registra como trabajo posterior"* (`design.md:312`). Que el límite es real se ve en producción: `POST /outbox/process-pending` es un request **autenticado** servido sobre `get_service_conn`, es decir corriendo con bypass y sin comprobación alguna. Ahí es deliberado (D5, el contexto de servicio existe para eso), pero muestra que la cobertura de este guard termina donde termina el contexto de request.
- **Modo *inefectividad*** — la adopción **se emite y no tiene efecto**. Es el que cierra el PR #470 y el que este change especifica. No estaba descrito en ninguna parte de la spec, ni siquiera como riesgo.

### Qué era exactamente el agujero del modo *inefectividad*

`get_db_conn` emitía `SET LOCAL ROLE authenticated` y entregaba la conexión sin comprobar nada. **Emitir un statement no es lo mismo que que el statement haya tenido efecto**: la membresía de rol que habilita la adopción se puede revocar del lado de la base, y un statement se puede tragar sin levantar error del lado del cliente. En cualquiera de esos casos el request seguía corriendo como `postgres` —el rol con `BYPASSRLS`— **creyendo estar bajo RLS y sin emitir ninguna señal**. Es la peor forma de un fallo de aislamiento: no rompe nada, no aparece en ningún log, y el aislamiento entre las 34 cuentas vuelve a depender de que cada repository se acuerde de filtrar. Un falla-abierto silencioso es peor que no tener el guard, porque además desactiva la sospecha.

Un tercer caso que suele citarse —un pooler que rutee el `SET LOCAL ROLE` a otra conexión física— **no** lo cierra esta comprobación: el `SELECT current_user` de verificación viaja por el mismo intermediario y puede aterrizar en la misma conexión equivocada. Ese caso lo cierra la **transacción explícita por request**, que fija ambos statements sobre la misma conexión física — y conviene atribuirla al requirement correcto, porque no es el de adopción: la transacción explícita la establece *Pool asyncpg con JWT-passthrough* (`openspec/specs/asyncpg-pool/spec.md:12`, el Paso 1), y lo que aporta el requirement de adopción es la cláusula que mete la adopción **dentro** de esa misma transacción (`:65`). Hacen falta las dos para que la adopción y su verificación caigan sobre la misma conexión física. La comprobación se apoya en esa co-locación; no la reemplaza. El comentario del código vivo lo nombra igual entre sus motivaciones, lo cual es correcto como intención pero no como garantía; la spec lo escribe con la precisión que corresponde y atribuye la garantía a esos dos requirements, no a esta comprobación.

### Por qué documentarlo ahora

La comprobación cuesta un round-trip extra por conexión de request, y hoy no hay ningún requirement que la exija. Es exactamente la clase de línea que una revisión de performance retira "porque es redundante, el `SET` ya se emitió" — que es el razonamiento que produjo el agujero la primera vez. Sin requirement, el guard depende de que nadie lo optimice; con requirement, retirarlo es romper un contrato.

## Goals / Non-Goals

**Goals**

- Fijar como contrato, en `asyncpg-pool`, la comprobación del rol efectivo posterior a la adopción: igualdad estricta, fallo cerrado, señal crítica, alcance de conexión de request.
- Describir el comportamiento **real** de `backend/core/database.py` (bloque "D6 bis"), ni más fuerte ni más débil.
- Dejar recuperable, después del archive, la evidencia de producción del 2026-08-28 **con sus límites declarados**, para que nadie la cite después como si hubiera probado más de lo que probó.
- Dejar registrados como candidatos los huecos detectados (test faltante, aserción faltante, spec ajena envejecida) en vez de taparlos dentro de este change.

**Non-Goals**

- **No se escribe ni se modifica código, ni tests.** Regla de oro del alcance: si aparece una divergencia entre lo que la spec quiere exigir y lo que hace `backend/core/database.py`, se corrige la **redacción de la spec** hacia el comportamiento real. Corregir el código sería otro change.
- **No se cierra el modo *omisión*** de D6. Su garantía estructural es el Paso 3 (OQ-2 opción (b)), trabajo futuro del cluster. Este change no lo adelanta ni lo reemplaza.
- **No se toca el requirement de adopción vigente** (*"El rol efectivo del camino de request no bypasea la seguridad a nivel de fila"*), que sigue siendo verdadero tal como está.
- **No se toca `multi-tenant` ni `python-backend`.**
- **No se legisla sobre el orden entre adopción de rol e inyección de claims**: eso ya lo fija el requirement de adopción ("SHALL ocurrir en el mismo punto y en la misma transacción, de modo que no puedan divergir").
- **No se especifica el atributo de bypass en sí.** Se verifica la **identidad** del rol efectivo contra el esperado; que ese rol no tenga bypass es propiedad del entorno, ya afirmada por el requirement de adopción.
- **Sin superficie frontend** (excepción declarada de la regla PO 2026-08-02, ver `proposal.md`).

## Decisions

### D1 — El delta va como `ADDED`, no como `MODIFIED` del requirement de adopción

La comprobación es **aguas abajo** de la adopción: otro modo de falla (la adopción no tomó), otro observable (un 503 con `logger.critical`), otra razón de existir (que un fallo de aislamiento no sea silencioso). El requirement vigente de línea 59 fija la **adopción** y su alcance transaccional, y no dice una palabra que haya que corregir; se releyó entero antes de decidir (task 1.5).

**Dónde sí se rozan, y por qué igual queda intacto.** Ese requirement tiene un escenario vigente que observa exactamente el mismo hecho que la comprobación —*"El usuario efectivo dentro de un request no bypasea las policies… THEN el rol efectivo es uno sin atributo de bypass de seguridad a nivel de fila"* (`openspec/specs/asyncpg-pool/spec.md:67-70`)— y lo hace en el registro **por descarte** que D3 declara inadmisible. No hay contradicción, y la razón es la que decide el alcance de este change: ese escenario afirma un **estado del sistema** ("el rol efectivo no tiene bypass"), no un **criterio de decisión** sobre el cual aceptar o rechazar un request. Su formulación negativa no legitima una comprobación por descarte, que es lo que D3 prohíbe; describe qué se observa, no con qué regla se resuelve. Por eso queda vigente sin modificación, y la **igualdad estricta vive sólo en el requirement nuevo**, que es donde el descarte sería un criterio y no una observación. Si esa distinción no se sostuviera, el escenario vigente necesitaría un bloque `MODIFIED` y el alcance de este change cambiaría — queda decidido explícitamente, no por omisión.

**Alternativa descartada: `MODIFIED` sobre el requirement de adopción, fundiendo ambos.** Descartada por dos razones. La normativa: produciría un requirement con dos tesis —"adoptá el rol" y "comprobá que la adopción tomó"—, que se lee peor y se viola parcialmente sin que el header lo refleje. La operativa: el formato `MODIFIED` obliga a transcribir **entero** el bloque de texto de seguridad que se sincronizó a `main` el 2026-08-27 (`0664619`, #469) y que no cambia un byte; cualquier error de transcripción en esa copia se convierte en un cambio silencioso de contrato de seguridad al archivar.

**Consecuencia registrada**: como el header del requirement es la clave de sincronización al archivar, el nombre nuevo no puede colisionar con los cuatro vigentes (una colisión funde bloques en silencio). Verificación explícita en task 3.3. Y como el formato de delta no cubre el `## Purpose` de la capability, éste se edita a mano en el mismo commit del archive (task 5.1): hoy resume la capability como pool + transacción + claims + adopción de rol, y sin esa edición la primera línea que lee cualquiera seguiría describiendo un sistema que sólo adopta el rol y no lo comprueba — que es la deriva exacta que este change corrige.

### D2 — El requirement se condiciona a la palanca de adopción en su primera línea

La primera línea del cuerpo dice "Cuando la adopción del rol restringido está activa, el sistema SHALL comprobar…", con el `SHALL` en esa misma línea.

**El argumento intuitivo para esta decisión es falso, y no se usa.** El razonamiento tentador es: "hay que condicionarlo para no contradecir el escenario vigente *Desplegar el código no cambia el comportamiento*". Contra el archivo, eso no se sostiene: el requirement de adopción **tampoco** se condiciona en su cuerpo —abre con "Dentro de la transacción de cada request autenticado, el sistema SHALL adoptar…"— y convive sin contradicción con ese escenario, porque la palanca está **factorizada** en el requirement de *Activación gradual y reversible*, que la cubre para toda la capability. Si ese fuera el motivo, el requirement nuevo debería escribirse sin condición, como los otros.

**El motivo verdadero es propio del requirement nuevo**: la **ausencia** del round-trip extra con la palanca apagada es contrato de **este** requirement, no un efecto colateral de la palanca general. Lo fija su escenario 6 ("Sin adopción de rol no hay comprobación ni costo adicional") y lo prueba el test parametrizado `test_get_db_conn_role_check_absent_when_step2_off` sobre dos combinaciones con el Paso 2 apagado: legacy (ambas palancas apagadas) y **Paso-1-solo** (transacción encendida, adopción apagada). El segundo es el que importa: es el que atrapa una comprobación sacada fuera del `if settings.tenancy_rls_role_enabled`, que es el modo de regresión más probable de este guard.

**Alternativa evaluada y descartada: sacar la condición del cuerpo** para igualar el registro de los otros cuatro requirements. Es defendible —la cláusula posterior "SHALL existir únicamente donde existe la adopción que verifica" ya cubre el caso apagado— pero se prefiere dejar la condicionalidad visible en la primera línea de un requirement de seguridad antes que la consistencia estilística: quien lo lea de apuro tiene que saber en la primera oración bajo qué condición aplica.

### D3 — Igualdad estricta contra el rol esperado, no criterio por descarte

El código lee `SELECT current_user` y compara `effective_role != "authenticated"`. Toda respuesta que no sea exactamente `authenticated` —incluida `None`— falla cerrado. La spec lo escribe como igualdad estricta explícita, con su `NOT SHALL` de descarte.

**Alternativa descartada: criterio negativo, "cualquier rol distinto del privilegiado".** Es exactamente el criterio de la mitigación que el design archivado ya declaraba: *"una verificación que afirma… que el usuario efectivo de la sesión **no** es el rol con BYPASSRLS"* (`design.md:137`). Ese criterio deja pasar una **respuesta ausente**, que es justo lo que devuelve un intermediario que se come el resultado — el caso que `test_get_db_conn_step2_fails_closed_when_role_check_returns_none` existe para prohibir. Escribir el descarte en la spec legitimaría una implementación estrictamente más débil que la mergeada.

Vale registrar la distancia completa entre la mitigación declarada en D6 y lo que efectivamente se mergeó, porque no es cosmética: aquella era una **aserción de test y de sondeo** —afirmar desde dentro de un request que el usuario efectivo no es `postgres`—, no un guard en runtime con rechazo. El PR #470 cambia las dos cosas a la vez: de aserción a guard por request, y de descarte a igualdad estricta.

**Corolario que también se escribe**: la comprobación lee el **rol efectivo** de la sesión, no el rol con el que se estableció la conexión —que informaría `postgres` aunque la adopción hubiese tomado—, y corre sobre la misma conexión y transacción donde correrán las consultas de negocio. Una comprobación fuera de ese alcance no prueba nada bajo un pooler en modo transacción, que es el escenario que la motiva.

### D4 — Un solo archivo de delta; `multi-tenant` y `python-backend` no se tocan

El impacto es un único `specs/asyncpg-pool/spec.md` con un solo bloque `## ADDED Requirements`. Al archivar, la capability pasa de 4 a 5 requirements con los cuatro vigentes byte por byte idénticos.

**Alternativa descartada: replicar la constatación en `multi-tenant` y/o `python-backend`.** Sus requirements siguen siendo verdaderos en lo que afirman **sobre el diseño**: uno afirma que ningún camino de acceso opera por diseño con un rol que bypasee las policies (una afirmación de tiempo de enumeración), el otro separa el contexto de request del de servicio. Ninguno de los dos habla de qué pasa cuando un camino **bien diseñado** falla en silencio, y ninguno cambia por este requirement. Replicar la constatación ahí sería texto normativo duplicado entre capabilities, que es como se producen las divergencias silenciosas que este proyecto ya pagó en otros lados.

Al mirarlas, igual, quedó detectado que dos pasajes de `python-backend` **ya envejecieron** por `tenancy-guard-caja-outbox`: el escenario *"Solo el router de payments usa get_service_conn"* (`openspec/specs/python-backend/spec.md:86`) y la cláusula *"Un endpoint que atiende a un usuario autenticado NOT SHALL usar el contexto de servicio"* (`:126`) describen invariantes que producción viola en dos lugares deliberados — pero no de la misma manera, y la distinción importa porque es la misma que D5 se cuida de hacer: `backend/routers/outbox.py:48` viola **las dos cosas** (es un request autenticado —`get_current_user` + `require_platform_admin`— servido por `get_service_conn`), mientras que `backend/routers/fiscal.py:330` viola **sólo el escenario de payments**, porque no atiende a ningún usuario autenticado: es un endpoint de máquina para `pg_cron` con shared secret y sin JWT (*"Autenticación: shared secret ONLY (no JWT)"*, `backend/routers/fiscal.py:334`). No es un bug de aislamiento, pero la spec afirma algo falso y ningún gate lo detecta. Se registra como candidato (Open Questions), no se arregla acá: es otra capability y sería cambio fuera de alcance.

### D5 — La exención del contexto de servicio se escribe como cláusula de alcance del requirement nuevo, formulada sobre el **contexto de conexión**

El requirement dice que la comprobación aplica únicamente a las conexiones obtenidas por el contexto de request, y que toda conexión obtenida por el contexto de servicio queda fuera de su alcance y no puede ser rechazada por él. Escrito así, la exención pertenece al mismo requirement que crea la obligación — que es donde se puede verificar de un vistazo que la obligación no aplica a `get_service_conn`.

**Primera alternativa descartada: escribirla como `MODIFIED` de `python-backend`.** Volvería a poner texto normativo sobre este guard en una capability que no lo define (ver D4).

**Segunda alternativa descartada, y más importante: formularla sobre *quién usa* el contexto de servicio** ("las operaciones de máquina quedan fuera"). Es falso hoy: `POST /outbox/process-pending` es un request **autenticado** servido por ese contexto. Formularla sobre el **contexto de conexión** —y no sobre la naturaleza del llamador— la deja verdadera sin afirmar nada de un camino ajeno que este change no testea. Deliberadamente no se afirma que el contexto de servicio atienda sólo operaciones de máquina.

## Risks / Trade-offs

- **Especificar un contrato más débil que el código** — el riesgo principal, y el único con consecuencia de seguridad. Si la spec dijera "un rol distinto del privilegiado" en lugar de "exactamente el rol esperado", legitimaría una implementación que deja pasar la respuesta ausente, que es el caso que el tercer test existe para prohibir; y una revisión futura podría "simplificar" el código hacia el contrato más débil sin romper ningún gate. **Mitigado** escribiendo la igualdad estricta de forma explícita, con su `NOT SHALL` de descarte y con la respuesta vacía nombrada dentro del texto normativo, más un escenario dedicado (escenario 3).
- **Exigir propiedades que el código no entrega** — el riesgo simétrico, y el que efectivamente hubo que corregir durante la redacción. El caso concreto: una versión previa del delta pedía que la **ausencia** de fallos fuera constatable sobre tráfico real. El código no entrega esa propiedad: el camino feliz loguea en `DEBUG` (`backend/core/database.py:156`) y el nivel efectivo de producción está por encima de `DEBUG`, así que ese registro no se emite y lo único observable es la **ausencia** de `CRITICAL`, indistinguible de "el guard se retiró", "la palanca está apagada" y "no pasó tráfico autenticado". Exigirlo habría sido cometer en la spec la misma falacia que motiva el change —ausencia de señal ≠ ausencia de problema— y habría dejado un requirement inverificable desde el día uno. **Se recortó del delta**; pedir señal positiva en un nivel que producción emita es cambio de código, fuera de alcance.
- **Escenarios sin respaldo de test** — el contrato queda fijado en la spec pero no en la suite en tres puntos, y eso se declara en vez de disimularse (mapeo completo en `tasks.md` 2.3, y en el cuerpo del PR por task 4.2): el **escenario 5** (rastro operativo) **no tiene ningún test** — se puede degradar `logger.critical` a `warning`, o sacarle el rol observado y el `sub`, y los 20 casos siguen verdes; el **escenario 4** (mensaje opaco) se apoya en una aserción lateral presente en un solo test (`assert "postgres" not in str(exc_info.value.detail).lower()`, ausente en el test de respuesta `None`); el **escenario 7** se apoya en `test_get_service_conn_step2_never_adopts_role_even_with_both_flags_on`, que cubre el GIVEN exacto y assertea que no se adopta el rol, pero no assertea `fetchval.assert_not_awaited()` — la mitad "no se le comprueba rol efectivo" es verdadera por construcción, no por aserción. Los tres van a Open Questions.
- **Costo por request no medido** — la comprobación agrega un round-trip por conexión de request. La spec acota el costo ("a lo sumo un intercambio adicional por conexión entregada", una vez por conexión y no una vez por consulta), pero **no se midió la latencia real** en producción. Trade-off aceptado y explícito: el costo de un round-trip contra un fallo de aislamiento silencioso entre 34 cuentas con dinero real no es una comparación difícil.
- **El requirement no cubre el modo *omisión*** — un lector apurado puede leer este change como "D6 quedó cerrado". No lo está: sólo su modo *inefectividad*. Mitigado escribiéndolo así en `CHANGES.md` (task 5.3), donde la nota de cierre parcial tiene que decir exactamente lo mismo que la nota que mantiene vivo el Paso 3 como residuo del cluster; escribir "D6 cerrado" a secas le sacaría la justificación al Paso 3.

## Evidencia de producción (2026-08-28)

Bloque de la task 1.6, con sus tres límites declarados. Vive acá para que sobreviva al archive del change y para que nadie la cite después probando más de lo que probó.

**Medición.** Ventana completa desde el merge de `d7b5214` (2026-08-27 11:26:08 -0300) hasta el 2026-08-28, sobre los logs de producción del backend en Render:

- **Cero rechazos de la comprobación**: `CRITICAL` = 0 y `503` = 0.
- **Control positivo**: `GET /products` = 18 — prueba que la búsqueda server-side encuentra tráfico cuando lo hay, es decir que el cero de arriba no es un cero de "la consulta no busca donde tiene que buscar".
- **Suite de esta sesión** (no una cita del PR): `pytest backend/tests/test_database.py -q` → **20 passed en 1.53 s**, cero fallos, cero skips. Veinte casos sobre diecinueve funciones, porque `test_get_db_conn_role_check_absent_when_step2_off` está parametrizado sobre dos combinaciones.

**Conclusión que sí se sostiene**: el guard nunca rechazó a nadie. Sin rechazos no hay daño histórico que auditar ni reparación pendiente.

**Tres límites, declarados textualmente:**

1. **`CRITICAL`, `BYPASSRLS` y `503` no son tres señales independientes.** Salen de la **misma y única línea** del código: el `logger.critical` —cuyo texto menciona BYPASSRLS— acompañado del `HTTPException(503)`, ambos dentro del mismo `if effective_role != "authenticated"`. Contarlas como tres confirmaciones es contar una vez y decir tres.
2. **No hay evidencia positiva por request de que la comprobación se haya ejecutado.** El camino de éxito loguea en `DEBUG` (`backend/core/database.py:156`) y el nivel efectivo de producción está por encima de `DEBUG`, así que no emite nada. Cuánto por encima no se afirma acá, y es a propósito: el backend **no configura logging en ninguna parte** —cero `basicConfig`, `setLevel` o `LOG_LEVEL` fuera de `.venv`, y no hay `render.yaml` versionado—, así que el logger de `backend/core/database.py` (`logging.getLogger(__name__)`, línea 13) hereda el nivel del root, que uvicorn no toca porque sólo configura sus propios loggers. El argumento no necesita más que "por encima de `DEBUG`"; nombrar un nivel concreto sería afirmar sin fuente, que es justo lo que este bloque existe para no hacer. Que corrió en los ≥127 requests autenticados de la ventana es una **inferencia** desde el estado de la palanca y desde que el código está en `main` — no una medición. El control positivo prueba que la búsqueda encuentra cosas, no que el guard corrió.
3. **No se midió latencia.** No corresponde afirmar que "cuesta lo que dijimos que iba a costar": el costo del round-trip extra está acotado por diseño y por la spec, no medido en producción.

## Migration Plan

**Ninguno.** El comportamiento ya está en producción desde el 2026-08-27 y este change publica archivos Markdown: no hay despliegue de código, no dispara migración de base de datos, no cambia ACLs ni policies, no cambia contrato HTTP y no hay palanca que mover. No hay rollback que preparar porque no hay corte: revertir este change es revertir texto.

Por la misma razón **no hay verificación post-merge en producción** (task 4.4). El estado de prod quedó constatado **antes** de escribir la spec, no después de mergearla — que es el orden correcto para un retro-spec. Si `Backend_Tests` fallara en el PR, es una regresión ajena: el diff no toca una línea de Python.

## Open Questions

Ninguna pregunta abierta bloquea este change. Lo que queda son candidatos detectados al redactarlo, verificados contra el árbol, que se registran en `CHANGES.md` (task 5.5) en lugar de resolverse acá — los dos primeros son cambios de código y el tercero es de otra capability, así que hacerlos acá violaría la regla de oro del alcance.

1. **Test del rastro operativo (escenario 5) — el hueco que más importa.** Hoy ningún test fija que el rechazo se registre con nivel `CRITICAL`, ni que incluya el rol efectivo observado y el `sub` del request. Verificado en esta sesión: `grep -niE "caplog|logger|critical|logging" backend/tests/test_database.py` devuelve una sola línea, y es un **comentario** (636). Consecuencia concreta: se puede degradar `logger.critical` a `warning`, o sacarle los dos datos, y los 20 casos siguen verdes. Es la señal sobre la que se apoya **toda** la verificación de producción de este change. Un test con `caplog` lo cierra.
2. **Aserción faltante en el test del contexto de servicio (escenario 7).** `test_get_service_conn_step2_never_adopts_role_even_with_both_flags_on` (`backend/tests/test_database.py:541`) assertea `transaction.assert_not_called()` y `execute.assert_not_called()`, pero no `conn_mock.fetchval.assert_not_awaited()`. La mitad "no se le comprueba rol efectivo" queda verdadera por construcción y no por aserción. Una línea lo cierra.
3. **`python-backend` envejecida por `tenancy-guard-caja-outbox`.** El escenario *"Solo el router de payments usa get_service_conn"* y la cláusula *"Un endpoint que atiende a un usuario autenticado NOT SHALL usar el contexto de servicio"* (`openspec/specs/python-backend/spec.md:86` y `:126`) describen invariantes que producción ya viola en dos exenciones de diseño, cada una a su manera: `backend/routers/outbox.py:48` viola las dos (request autenticado con `require_platform_admin` servido por `get_service_conn`) y `backend/routers/fiscal.py:330` viola sólo el escenario de payments, por ser un endpoint de máquina con shared secret y sin JWT de usuario. No es un bug de aislamiento, pero la spec afirma algo falso y ningún gate lo detecta. Corresponde un change propio de corrección de esa capability.

**Residuos del cluster que este change no toca y que siguen vivos** (ya anotados desde `v31-tenancy-pool-rls`, se repiten acá sólo para que no se los dé por cerrados junto con este requirement): el **Paso 3** —rol de login sin `BYPASSRLS`, que es lo que cierra el modo *omisión* de D6— y el **retiro de las dos palancas** junto con el camino de código legacy.
