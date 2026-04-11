import Clibgit2

extension git_strarray {
    func filter(_ isIncluded: (String) -> Bool) -> [String] {
        return map { $0 }.filter(isIncluded)
    }

    func map<T>(_ transform: (String) -> T) -> [T] {
        return (0..<self.count).compactMap { i -> T? in
            guard let cStr = self.strings[Int(i)] else { return nil }
            guard let string = String(validatingUTF8: cStr) else { return nil }
            return transform(string)
        }
    }
}
