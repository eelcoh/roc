platform ""
    requires {
        handle! : Http.Request => Http.Response
    }
    exposes [Http, Clock, Random, Kv, Config, Log, Postgres, Sql, Row, Db]
    packages {}
    provides { "roc_handle": handle_for_host! }
    hosted {
        "roc_clock_now": Clock.now!,
        "roc_config_text": Config.text!,
        "roc_kv_delete": Kv.delete!,
        "roc_kv_get": Kv.get_host!,
        "roc_kv_put": Kv.put!,
        "roc_log_error": Log.error!,
        "roc_log_info": Log.info!,
        "roc_log_warn": Log.warn!,
        "roc_pg_run": Postgres.run_host!,
        "roc_random_u64": Random.u64!,
    }
    targets: {
        inputs_dir: "targets/",
        x64glibc: { inputs: [app], output: Archive },
        arm64glibc: { inputs: [app], output: Archive },
        x64musl: { inputs: [app], output: Archive },
        arm64musl: { inputs: [app], output: Archive },
        x64mac: { inputs: [app], output: Archive },
        arm64mac: { inputs: [app], output: Archive },
        x64v1elf: { inputs: [app], output: Archive },
    }

import Http
import Clock
import Config
import Db
import Kv
import Log
import Postgres
import Random
import Row
import Sql

## Called by the host for each request, with the request in pieces that are
## easy to hand over through the C ABI.
handle_for_host! : Str, Str, Str, List((Str, Str)), List(U8) => Http.Response
handle_for_host! = |method, path, query, headers, body|
    handle!({ method, path, query, headers, body })
