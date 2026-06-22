# Architecture

openfugu separates planning, adapter invocation, process runtime, workspace
isolation, verification, and local observability.

Adapters describe official CLI compatibility and build argv arrays. They do not
own process lifecycle. The process runtime executes argv without shell strings.
