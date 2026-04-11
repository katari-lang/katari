use std::io::{self, Read};

/// Read an unsigned LEB128 encoded u32.
pub fn read_u32<R: Read>(reader: &mut R) -> io::Result<u32> {
    let mut result: u32 = 0;
    let mut shift: u32 = 0;
    loop {
        let mut buf = [0u8; 1];
        reader.read_exact(&mut buf)?;
        let byte = buf[0];
        result |= ((byte & 0x7f) as u32) << shift;
        if byte & 0x80 == 0 {
            return Ok(result);
        }
        shift += 7;
        if shift >= 35 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "LEB128 u32 overflow",
            ));
        }
    }
}

/// Read a signed LEB128 encoded i64 (for arbitrary-precision integers).
pub fn read_signed<R: Read>(reader: &mut R) -> io::Result<i64> {
    let mut result: i64 = 0;
    let mut shift: u32 = 0;
    let mut byte;
    loop {
        let mut buf = [0u8; 1];
        reader.read_exact(&mut buf)?;
        byte = buf[0];
        result |= ((byte & 0x7f) as i64) << shift;
        shift += 7;
        if byte & 0x80 == 0 {
            break;
        }
        if shift >= 70 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "signed LEB128 overflow",
            ));
        }
    }
    // Sign extend
    if shift < 64 && (byte & 0x40) != 0 {
        result |= !0i64 << shift;
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn test_read_u32_zero() {
        let mut r = Cursor::new([0x00]);
        assert_eq!(read_u32(&mut r).unwrap(), 0);
    }

    #[test]
    fn test_read_u32_single_byte() {
        let mut r = Cursor::new([0x05]);
        assert_eq!(read_u32(&mut r).unwrap(), 5);
    }

    #[test]
    fn test_read_u32_multi_byte() {
        // 624485 = 0xE5 0x8E 0x26
        let mut r = Cursor::new([0xE5, 0x8E, 0x26]);
        assert_eq!(read_u32(&mut r).unwrap(), 624485);
    }

    #[test]
    fn test_read_signed_positive() {
        let mut r = Cursor::new([0x08]);
        assert_eq!(read_signed(&mut r).unwrap(), 8);
    }

    #[test]
    fn test_read_signed_negative() {
        // -1 in signed LEB128 = 0x7f
        let mut r = Cursor::new([0x7f]);
        assert_eq!(read_signed(&mut r).unwrap(), -1);
    }

    #[test]
    fn test_read_signed_negative_multi() {
        // -123456 in signed LEB128
        let mut r = Cursor::new([0xC0, 0xBB, 0x78]);
        assert_eq!(read_signed(&mut r).unwrap(), -123456);
    }
}
