.PHONY: hello agent remote test clean

hello:
	mojo run hello.mojo

agent:
	mojo run agent.mojo

remote:
	mojo run remote_hello.mojo

test:
	mojo run tests/local_test.mojo

clean:
	find . -name '*.pyc' -delete
	find . -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
