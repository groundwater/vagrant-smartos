all: 
	@echo "Usage: make package"

package: vagrant-tools.tar.gz

clean:
	rm -f vagrant-tools.tar.gz

vagrant-tools.tar.gz: GLOBALZ
	tar -czf vagrant-tools.tar.gz -C GLOBALZ opt
