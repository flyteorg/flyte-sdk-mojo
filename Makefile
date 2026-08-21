.PHONY: hello agent fib fib-fail pipeline python-task simulate test test-worker local clean clean-build

# Examples live in examples/ and the SDK in flyte/, so Mojo needs -I . to
# resolve `from flyte import *`. Run these from the repo root.
MOJO = mojo run -I .

hello:
	$(MOJO) examples/hello.mojo

agent:
	$(MOJO) examples/agent.mojo

fib:
	$(MOJO) examples/fib.mojo

pipeline:                       ## multi-action workflow: extract -> fan-out -> summarize
	$(MOJO) examples/pipeline.mojo

fib-fail:                       ## failure path: the Mojo error comes back from the cluster
	FIB_N=200 $(MOJO) examples/fib.mojo

python-task:                    ## escape hatch: drive an existing Python task
	$(MOJO) examples/python_task.mojo

local:                          ## run the examples in-process, ignoring any cluster config
	HOME=$$(mktemp -d) $(MOJO) examples/hello.mojo
	HOME=$$(mktemp -d) $(MOJO) examples/pipeline.mojo
	HOME=$$(mktemp -d) $(MOJO) examples/agent.mojo

simulate:                       ## the multi-action tree, one process per action, no cluster
	FLYTE_MOJO_SIM_HOME=$$(mktemp -d) python tests/simulate.py examples/pipeline.mojo etl.pipeline 4
	FLYTE_MOJO_SIM_HOME=$$(mktemp -d) python tests/simulate.py examples/agent.mojo agent.solve "what is mojo"

test:
	$(MOJO) tests/local_test.mojo
	$(MAKE) test-worker

test-worker:                    ## the worker role and control protocol, no cluster needed
	@./tests/worker_checks.sh

clean:
	find . -name '*.pyc' -delete
	find . -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

clean-build:                    ## drop cached linux/amd64 builds (keeps the builder image)
	rm -rf _flyte_mojo/build_*
