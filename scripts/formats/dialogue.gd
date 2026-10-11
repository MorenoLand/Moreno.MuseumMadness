class_name Dialogue
extends RefCounted


static func entries(record: PackedByteArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var p := 0
	while p + 2 <= record.size() and record[p] != 0xFE:
		var kind := record[p]
		var param := record[p + 1]
		p += 2
		var end := record.find(0, p)
		if end < 0:
			end = record.size()
		out.append({"kind": kind, "param": param, "text": record.slice(p, end).get_string_from_ascii()})
		p = end + 1
	return out
