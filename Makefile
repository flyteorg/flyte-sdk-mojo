.PHONY: hello agent fib fib-fail pipeline python-task simulate test test-worker local clean clean-build

# Each example is a single .mojo file. With a cluster config it compiles
# itself for linux/amd64 and runs there; without one it runs in-process.

hello:
	mojo run hello.mojo

agent:
	mojo run agent.mojo

fib:
	mojo run fib.mojo

pipeline:                       ## multi-action workflow: extract -> fan-out -> summarize
	mojo run pipeline.mojo

fib-fail:                       ## failure path: the Mojo error comes back from the cluster
	FIB_N=200 mojo run fib.mojo

python-task:                    ## escape hatch: drive an existing Python task
	mojo run python_task.mojo

local:                          ## run the examples in-process, ignoring any cluster config
	HOME=$$(mktemp -d) mojo run hello.mojo
	HOME=$$(mktemp -d) mojo run pipeline.mojo
	HOME=$$(mktemp -d) mojo run agent.mojo

simulate:                       ## the multi-action tree, one process per action, no cluster
	FLYTE_MOJO_SIM_HOME=$$(mktemp -d) python tests/simulate.py pipeline.mojo etl.pipeline 4
	FLYTE_MOJO_SIM_HOME=$$(mktemp -d) python tests/simulate.py agent.mojo agent.solve "what is mojo"

test:
	mojo run tests/local_test.mojo
	$(MAKE) test-worker

test-worker:                    ## the worker role and control protocol, no cluster needed
	@./tests/worker_checks.sh

clean:
	find . -name '*.pyc' -delete
	find . -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

clean-build:                    ## drop cached linux/amd64 builds (keeps the builder image)
	rm -rf _flyte_mojo/build_*
