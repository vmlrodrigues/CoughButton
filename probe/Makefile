BINS = axgate axdump axctl axobserve axpoll axwindows

all: $(BINS)

%: %.swift
	swiftc -O $< -o $@

clean:
	rm -f $(BINS)

.PHONY: all clean
