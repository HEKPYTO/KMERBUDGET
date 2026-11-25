#include "fisk/fisk.hpp"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <map>
#include <string>
#include <vector>

static std::uint64_t revcomp(std::uint64_t v, unsigned w) {
    std::uint64_t o = 0;
    for (unsigned i = 0; i < w; ++i) { o = (o << 2) | (3 - (v & 3)); v >>= 2; }
    return o;
}

int main(int argc, char** argv) {
    if (argc != 3) { std::fprintf(stderr, "usage: parity <fasta> <mask>\n"); return 2; }
    std::ifstream in(argv[1]);
    std::string seq, line;
    while (std::getline(in, line)) {
        if (!line.empty() && line[0] == '>') continue;
        for (char c : line) if (!std::isspace(static_cast<unsigned char>(c))) seq += c;
    }
    std::string mask = argv[2];
    unsigned weight = static_cast<unsigned>(std::count(mask.begin(), mask.end(), '1'));
    fisk::SpacedKmerMaskForms<fisk::Layout::kMSB> forms({mask});
    std::map<std::uint64_t, std::uint64_t> counts;
    fisk::for_each_spaced_kmer<fisk::InputCheck::kChecked, fisk::Encoding::kACGT, fisk::Layout::kMSB>(
        seq, forms,
        [&](std::size_t, std::size_t, fisk::SpacedKmerAcgtMsb kmer) {
            const std::uint64_t f = kmer.value;
            counts[std::min(f, revcomp(f, weight))] += 1;
        });
    std::printf("kmer\tcount\n");
    const char alphabet[] = "ACGT";
    for (auto const& [key, count] : counts) {
        std::string text(weight, 'A');
        for (unsigned i = 0; i < weight; ++i) text[i] = alphabet[(key >> (2 * (weight - 1 - i))) & 3];
        std::printf("%s\t%llu\n", text.c_str(), static_cast<unsigned long long>(count));
    }
}
